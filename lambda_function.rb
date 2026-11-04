require 'aws-sdk-s3'
require 'aws-sdk-ssm'
require_relative 'lib/tide_calendar'

class CalendarPublisher
  def initialize(calendar:, s3:, bucket:, key:, days:)
    @calendar = calendar
    @s3 = s3
    @bucket = bucket
    @key = key
    @days = days
  end

  def publish(now: Time.now)
    start_date = now.getlocal(TideCalendar::JAPAN_OFFSET).to_date
    body = @calendar.generate(start_date: start_date, days: @days)
    @s3.put_object(bucket: @bucket, key: @key, body: body,
                   content_type: 'text/calendar; charset=utf-8',
                   cache_control: 'public, max-age=3600',
                   metadata: { 'generated-at' => now.utc.iso8601 })
    { start_date: start_date.iso8601, days: @days, bytes: body.bytesize }
  end
end

def lambda_handler(event:, context:)
  parameter = Aws::SSM::Client.new.get_parameter(name: ENV.fetch('LOCATION_PARAMETER_NAME'))
  location = JSON.parse(parameter.parameter.value)
  result = CalendarPublisher.new(
    calendar: TideCalendar.new(pc: location.fetch('prefecture_code'), hc: location.fetch('harbor_code')),
    s3: Aws::S3::Client.new,
    bucket: ENV.fetch('CALENDAR_BUCKET'),
    key: ENV.fetch('CALENDAR_KEY'),
    days: Integer(ENV.fetch('CALENDAR_DAYS'))
  ).publish
  puts JSON.generate(result)
  result
end
