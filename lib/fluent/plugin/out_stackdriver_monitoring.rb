require 'fluent/output'
require_relative 'stackdriver/client'

module Fluent
  class StackdriverMonitoringOutput < BufferedOutput
    Fluent::Plugin.register_output('stackdriver_monitoring', self)

    config_param :project, :string
    config_section :custom_metrics, required: true, multi: false do
      config_param :key, :string
      config_param :type, :string
      config_param :metric_kind, :enum, list: [:GAUGE, :CUMULATIVE]
      config_param :value_type, :enum, list: [:BOOL, :INT64, :DOUBLE] # todo: implement :DISTRIBUTION
      config_param :time_interval, :time, default: 0
    end

    TYPE_PREFIX = 'custom.googleapis.com/'.freeze
    PAST_DATA_TIME_LIMIT = 60 * 60 * 24  # 24h

    def configure(conf)
      super

      unless is_custom_metric? @custom_metrics.type
        raise Fluent::ConfigError.new "custom_metrics.type must start with \"#{TYPE_PREFIX}\""
      end

      if @custom_metrics.metric_kind == :CUMULATIVE
        if @custom_metrics.time_interval == 0
          raise Fluent::ConfigError.new 'time_interval must be greater than 0 if metric_kind is set to CUMULATIVE'
        end
        if @custom_metrics.value_type == :BOOL
          raise Fluent::ConfigError.new 'custom metric does not support BOOL value type if metric_kind is set to CUMULATIVE'
        end
      end

      @client = Fluent::StackdriverMonitoring::Writer.new @project, @custom_metrics, log
    end

    def start
      super
      @client.start
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      chunk.msgpack_each do |tag, time, record|
        if (Time.now.to_i - time) >= PAST_DATA_TIME_LIMIT
          log.warn 'Drop data point because it cannot be written more than 24h in the past', time: Time.at(time).to_s, metric_type: @custom_metrics.type
          next
        end

        value = record[@custom_metrics.key]
        start_time = time - @custom_metrics.time_interval
        @client.write start_time, time, value
      end
    end

    private
    def is_custom_metric?(metric_type)
      metric_type.start_with? TYPE_PREFIX
    end
  end
end
