require 'fluent/output'
require 'google/api/metric_pb'
require 'google/cloud/monitoring/v3/metric_service_api'
require 'google/protobuf/repeated_field'
require 'google/protobuf/timestamp_pb'

module Fluent
  class StackdriverOutput < BufferedOutput
    Fluent::Plugin.register_output('stackdriver', self)

    config_param :project, :string
    config_section :custom_metrics, required: true, multi: false do
      config_param :key, :string
      config_param :type, :string
      config_param :metric_kind, :enum, list: [:GAUGE, :DELTA, :CUMULATIVE]
      config_param :value_type, :enum, list: [:BOOL, :INT64, :DOUBLE, :STRING] # todo: implement :DISTRIBUTION, :MONEY
    end

    TYPE_PREFIX = 'custom.googleapis.com/'.freeze

    def configure(conf)
      super

      unless @custom_metrics.type.start_with? TYPE_PREFIX
        raise "custom_metrics.type must start with \"#{TYPE_PREFIX}\""
      end

      @project_name = Google::Cloud::Monitoring::V3::MetricServiceApi.project_path @project
      @metric_name = Google::Cloud::Monitoring::V3::MetricServiceApi.metric_descriptor_path @project, @custom_metrics.type
    end

    def start
      super

      @metric_service_api = Google::Cloud::Monitoring::V3::MetricServiceApi.new
      @metric_descriptor = create_metric_descriptor
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      chunk.msgpack_each do |tag, time, record|
        time_series = create_time_series
        value = record[@custom_metrics.key]

        point = Google::Monitoring::V3::Point.new
        point.interval = create_time_interval time
        point.value = create_typed_value value
        time_series.points.push point

        log.debug "Create time series", time: Time.at(time).to_s, value: value
        # Only one point can be written per TimeSeries per request.
        @metric_service_api.create_time_series @project_name, [time_series]
      end
    end

    private
    def create_metric_descriptor
      metric_descriptor = @metric_service_api.get_metric_descriptor(@metric_name)

      if metric_descriptor.is_a? Google::Api::MetricDescriptor
        log.info "succeed to get metric descripter:#{@metric_name}"
        return metric_descriptor
      end

      metric_descriptor = Google::Api::MetricDescriptor.new
      metric_descriptor.type = @custom_metrics.type
      metric_descriptor.metric_kind = @custom_metrics.metric_kind
      metric_descriptor.value_type = @custom_metrics.value_type
      metric_descriptor = @metric_service_api.create_metric_descriptor(@project_name, metric_descriptor)
      log.info "succeed to create metric descripter:#{@metric_name}"

      metric_descriptor
    end

    def create_time_series
      time_series = Google::Monitoring::V3::TimeSeries.new

      metric = Google::Api::Metric.new
      metric.type = @metric_descriptor.type
      time_series.metric = metric

      time_series.metric_kind = @metric_descriptor.metric_kind
      time_series.value_type = @metric_descriptor.value_type

      time_series
    end

    def create_time_interval(time)
      time_interval = Google::Monitoring::V3::TimeInterval.new
      time_interval.start_time = Google::Protobuf::Timestamp.new seconds: time
      time_interval.end_time = Google::Protobuf::Timestamp.new seconds: time

      time_interval
    end

    def create_typed_value(value)
      typed_value = Google::Monitoring::V3::TypedValue.new
      case @metric_descriptor.value_type
      when :BOOL
        typed_value.bool_value = value.to_bool
      when :INT64
        typed_value.int64_value = value.to_i
      when :DOUBLE
        typed_value.double_value = value.to_f
      when :STRING
        typed_value.string_value = value.to_s
      else
        raise 'Unknown value_type!'
      end

      typed_value
    end
  end
end
