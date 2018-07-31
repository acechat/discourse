require "sidekiq/pausable"
require "sidekiq/web"

Sidekiq.configure_client do |config|
  config.redis = Discourse.sidekiq_redis_config
end

Sidekiq.configure_server do |config|
  config.redis = Discourse.sidekiq_redis_config

  config.server_middleware do |chain|
    chain.add Sidekiq::Pausable
  end
end

MiniScheduler.configure do |config|

  config.redis = $redis

  config.job_exception_handler do |ex, context|
    Discourse.handle_job_exception(ex, context)
  end

  config.job_ran do |stat|
    DiscourseEvent.trigger(:scheduled_job_ran, stat)
  end

  config.before_sidekiq_web_request do
    RailsMultisite::ConnectionManagement.establish_connection(db: 'default')
  end

end

if Sidekiq.server?
  # defer queue should simply run in sidekiq
  Scheduler::Defer.async = false

  # warm up AR
  RailsMultisite::ConnectionManagement.each_connection do
    (ActiveRecord::Base.connection.tables - %w[schema_migrations]).each do |table|
      table.classify.constantize.first rescue nil
    end
  end

  Rails.application.config.after_initialize do
    scheduler_hostname = ENV["UNICORN_SCHEDULER_HOSTNAME"]

    if !scheduler_hostname || scheduler_hostname.split(',').include?(`hostname`.strip)
      MiniScheduler.start
    end
  end
end

Sidekiq.logger.level = Logger::WARN

class SidekiqLogsterReporter < Sidekiq::ExceptionHandler::Logger
  def call(ex, context = {})

    return if Jobs::HandledExceptionWrapper === ex
    Discourse.reset_active_record_cache_if_needed(ex)

    # Pass context to Logster
    fake_env = {}
    context.each do |key, value|
      Logster.add_to_env(fake_env, key, value)
    end

    text = "Job exception: #{ex}\n"
    if ex.backtrace
      Logster.add_to_env(fake_env, :backtrace, ex.backtrace)
    end

    Logster.add_to_env(fake_env, :current_hostname, Discourse.current_hostname)

    Thread.current[Logster::Logger::LOGSTER_ENV] = fake_env
    Logster.logger.error(text)
  rescue => e
    Logster.logger.fatal("Failed to log exception #{ex} #{hash}\nReason: #{e.class} #{e}\n#{e.backtrace.join("\n")}")
  ensure
    Thread.current[Logster::Logger::LOGSTER_ENV] = nil
  end
end

Sidekiq.error_handlers.clear
Sidekiq.error_handlers << SidekiqLogsterReporter.new
