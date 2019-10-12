require 'google/api/metric_pb'
require 'google/cloud/monitoring/v3/metric_service_client'
require 'google/protobuf/repeated_field'
require 'google/protobuf/timestamp_pb'

module Fluent
  module StackdriverMonitoring
    class Error < StandardError
    end

    class Writer
      RETRY_LIMIT = 5

      def initialize(project, custom_metrics, log)
        @custom_metrics = custom_metrics
        @project_name = Google::Cloud::Monitoring::V3::MetricServiceClient.project_path project
        @metric_name = Google::Cloud::Monitoring::V3::MetricServiceClient.metric_descriptor_path project, custom_metrics.type
        @log = log
      end

      def start
        @metric_service_client = Google::Cloud::Monitoring::V3::MetricServiceClient.new
        @metric_descriptor = create_metric_descriptor
      end

      def write(start_time, end_time, value)
        retry_count = 0
        begin
          time_series = create_time_series
          point = Google::Monitoring::V3::Point.new
          point.interval = create_time_interval start_time, end_time
          point.value = create_typed_value value
          time_series.points.push point

          log.debug "Create time series", start_time: Time.at(start_time).to_s, end_time: Time.at(end_time).to_s, value: value, metric_name: @metric_name
          # Only one point can be written per TimeSeries per request.
          @metric_service_client.create_time_series @project_name, [time_series]
        rescue Google::Gax::RetryError => ex
          retry_count += 1
          if retry_count >= RETRY_LIMIT
            raise ex
          end
          log.info "Google::Gax::RetryError occured", error_msg: ex.to_s
          # The Stackdriver API recommends sending at most 1 TimeSeries value every 30s
          sleep 30
          retry
        end
      end

      private
      def log
        @log
      end

      def create_metric_descriptor
        begin
          metric_descriptor = @metric_service_client.get_metric_descriptor(@metric_name)
          log.info "Succeed to get metric descripter", metric_name: @metric_name
          return metric_descriptor
        rescue Google::Gax::RetryError
          log.info "Failed to get metric descripter", metric_name: @metric_name
        end

        metric_descriptor = Google::Api::MetricDescriptor.new
        metric_descriptor.type = @custom_metrics.type
        metric_descriptor.metric_kind = @custom_metrics.metric_kind
        metric_descriptor.value_type = @custom_metrics.value_type
        metric_descriptor = @metric_service_client.create_metric_descriptor(@project_name, metric_descriptor)
        log.info "Succeed to create metric descripter", metric_name: @metric_name

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

      def create_time_interval(start_time, end_time)
        time_interval = Google::Monitoring::V3::TimeInterval.new
        time_interval.start_time = Google::Protobuf::Timestamp.new seconds: start_time
        time_interval.end_time = Google::Protobuf::Timestamp.new seconds: end_time
        time_interval
      end

      def create_typed_value(value)
        typed_value = Google::Monitoring::V3::TypedValue.new
        case @metric_descriptor.value_type
        when :BOOL
          typed_value.bool_value = !!value
        when :INT64
          typed_value.int64_value = value.to_i
        when :DOUBLE
          typed_value.double_value = value.to_f
        else
          raise Error.new 'Unknown value_type!'
        end

        typed_value
      end
    end
  end
end
