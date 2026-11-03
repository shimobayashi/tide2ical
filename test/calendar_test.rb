require 'minitest/autorun'
require 'minitest/mock'
require 'open3'
require 'rbconfig'
require_relative '../lambda_function'

class CalendarTest < Minitest::Test
  START_DATE = Date.new(2026, 12, 15)

  def response_for(date)
    chart = 30.times.to_h do |index|
      day = date + index
      midnight = Time.new(day.year, day.month, day.day, 0, 0, 0, '+09:00')
      [day.iso8601, {
        'sun' => { 'rise' => '06:04', 'set' => '16:46' },
        'edd' => [{ 'unix' => (midnight + 3600).to_i * 1000, 'cm' => 62.7 }],
        'flood' => [{ 'unix' => (midnight + 7200).to_i * 1000, 'cm' => 151.6 }]
      }]
    end
    { 'status' => 1, 'tide' => {
      'port' => { 'prefecture_code' => 1, 'harbor_code' => 1, 'harbor_namej' => 'テスト港' },
      'chart' => chart
    } }
  end

  def generator(&change)
    @requests = []
    fetcher = lambda do |uri|
      params = URI.decode_www_form(uri.query).to_h
      @requests << params
      date = Date.new(*params.values_at('yr', 'mn', 'dy').map(&:to_i))
      response = response_for(date)
      change&.call(response, @requests.length)
      response
    end
    TideCalendar.new(pc: 1, hc: 1, fetcher: fetcher)
  end

  def parsed_calendar(calendar = generator, days: 90)
    Icalendar::Calendar.parse(calendar.generate(start_date: START_DATE, days: days)).fetch(0)
  end

  def test_generates_exactly_90_days_across_year_boundary
    calendar = parsed_calendar
    assert_equal 360, calendar.events.size
    dates = calendar.events.map { |event| event.dtstart.to_time.getlocal('+09:00').to_date }.uniq.sort
    assert_equal (START_DATE...(START_DATE + 90)).to_a, dates
    assert_equal %w[2026-12-15 2027-01-14 2027-02-13], @requests.map { |p| format('%04d-%02d-%02d', *p.values_at('yr', 'mn', 'dy').map(&:to_i)) }
    assert @requests.all? { |p| p.values_at('pc', 'hc', 'rg') == %w[1 1 month] }
    assert_equal ['テスト港の潮汐表'], calendar.custom_properties['x_wr_calname'].map(&:to_s)
    assert_equal 360, calendar.events.map(&:uid).uniq.size
  end

  def test_sunrise_and_tides_use_japanese_time_even_in_utc_environment
    calendar = parsed_calendar(days: 1)
    times = calendar.events.map { |event| event.dtstart.to_time.utc.iso8601 }
    assert_equal %w[2026-12-14T21:04:00Z 2026-12-15T07:46:00Z 2026-12-14T16:00:00Z 2026-12-14T17:00:00Z], times
    assert calendar.events.all? { |event| event.dtend.to_time - event.dtstart.to_time == 3600 }
  end

  def test_uid_stays_the_same_after_time_and_height_corrections
    original = parsed_calendar(days: 1)
    corrected = parsed_calendar(generator do |response, _|
      chart = response['tide']['chart'][START_DATE.iso8601]
      chart['sun']['rise'] = '06:05'
      chart['edd'][0]['cm'] = 63.0
      chart['edd'][0]['unix'] += 60_000
    end, days: 1)
    assert_equal original.events.map(&:uid), corrected.events.map(&:uid)
    refute_equal original.events.first.dtstart, corrected.events.first.dtstart
    refute_equal original.events[2].summary, corrected.events[2].summary
  end

  def test_normalizes_sixty_minutes_from_api
    calendar = parsed_calendar(generator do |response, _|
      response['tide']['chart'][START_DATE.iso8601]['sun']['rise'] = '06:60'
    end, days: 1)
    assert_equal '2026-12-14T22:00:00Z', calendar.events.first.dtstart.to_time.utc.iso8601
  end

  def test_rejects_empty_or_incomplete_responses
    [lambda { |response| response['tide']['chart'].clear },
     lambda { |response| response['tide']['chart'].delete(START_DATE.iso8601) }].each do |change|
      assert_raises(TideCalendar::InvalidResponse) { parsed_calendar(generator { |response, _| change.call(response) }) }
    end
  end

  def test_rejects_api_errors_and_wrong_ports
    [lambda { |response| response['status'] = 0 },
     lambda { |response| response['tide']['port']['harbor_code'] = 8 }].each do |change|
      assert_raises(TideCalendar::InvalidResponse) { parsed_calendar(generator { |response, _| change.call(response) }) }
    end
  end

  def test_rejects_invalid_sunrise_and_tide_data
    [lambda { |chart| chart['sun']['rise'] = '25:00' },
     lambda { |chart| chart['edd'] = nil },
     lambda { |chart| chart['flood'][0]['cm'] = nil },
     lambda { |chart| chart['edd'][0]['unix'] -= 86_400_000 }].each do |change|
      calendar = generator { |response, _| change.call(response['tide']['chart'][START_DATE.iso8601]) }
      assert_raises(TideCalendar::InvalidResponse) { parsed_calendar(calendar) }
    end
  end

  def test_does_not_upload_when_second_request_fails
    calendar = generator { |_, count| raise IOError, 'API unavailable' if count == 2 }
    s3 = Aws::S3::Client.new(stub_responses: true)
    publisher = CalendarPublisher.new(calendar: calendar, s3: s3, bucket: 'calendar', key: 'tide.ics', days: 90)
    assert_raises(IOError) { publisher.publish(now: START_DATE.to_time) }
    assert_empty s3.api_requests
  end

  def test_publishes_ics_once_after_all_requests_succeed
    s3 = Aws::S3::Client.new(stub_responses: true)
    publisher = CalendarPublisher.new(calendar: generator, s3: s3, bucket: 'calendar', key: 'tide.ics', days: 90)
    result = publisher.publish(now: Time.utc(2026, 12, 14, 16))
    assert_equal '2026-12-15', result[:start_date]
    assert_equal 1, s3.api_requests.size
    request = s3.api_requests.first[:params]
    assert_equal 'calendar', request[:bucket]
    assert_equal 'tide.ics', request[:key]
    assert_equal 'text/calendar; charset=utf-8', request[:content_type]
    assert_equal 'public, max-age=3600', request[:cache_control]
    assert_equal '2026-12-14T16:00:00Z', request[:metadata]['generated-at']
    assert_equal 360, Icalendar::Calendar.parse(request[:body]).first.events.size
  end

  def test_s3_failure_is_reported_for_lambda_retry
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:put_object, 'AccessDenied')
    publisher = CalendarPublisher.new(calendar: generator, s3: s3, bucket: 'calendar', key: 'tide.ics', days: 90)
    assert_raises(Aws::S3::Errors::AccessDenied) { publisher.publish(now: START_DATE.to_time) }
  end

  def test_cli_rejects_zero_repeat_before_fetching
    _, stderr, status = Open3.capture3(RbConfig.ruby, File.expand_path('../tide2ical.rb', __dir__), '--repeat', '0')
    refute status.success?
    assert_includes stderr, 'days must be positive'
  end

  def with_handler_environment
    values = {
      'LOCATION_PARAMETER_NAME' => '/example/location',
      'CALENDAR_BUCKET' => 'example-calendar',
      'CALENDAR_KEY' => 'tide.ics',
      'CALENDAR_DAYS' => '90'
    }
    original = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_handler_reads_location_from_ssm_without_logging_it
    ssm = Aws::SSM::Client.new(region: 'ap-northeast-1', stub_responses: true)
    ssm.stub_responses(:get_parameter, parameter: { value: '{"prefecture_code":1,"harbor_code":1}' })
    s3 = Aws::S3::Client.new(stub_responses: true)
    calendar = generator
    create_calendar = lambda do |pc:, hc:|
      assert_equal [1, 1], [pc, hc]
      calendar
    end
    with_handler_environment do
      stdout, = capture_io do
        Aws::SSM::Client.stub(:new, ssm) do
          Aws::S3::Client.stub(:new, s3) do
            TideCalendar.stub(:new, create_calendar) { lambda_handler(event: {}, context: nil) }
          end
        end
      end
      assert_equal %w[bytes days start_date], JSON.parse(stdout).keys.sort
    end
    assert_equal({ name: '/example/location' }, ssm.api_requests.first[:params])
    assert_equal 1, s3.api_requests.size
  end

  def test_missing_location_does_not_upload
    ssm = Aws::SSM::Client.new(region: 'ap-northeast-1', stub_responses: true)
    ssm.stub_responses(:get_parameter, 'ParameterNotFound')
    s3 = Aws::S3::Client.new(stub_responses: true)
    with_handler_environment do
      Aws::SSM::Client.stub(:new, ssm) do
        Aws::S3::Client.stub(:new, s3) do
          assert_raises(Aws::SSM::Errors::ParameterNotFound) { lambda_handler(event: {}, context: nil) }
        end
      end
    end
    assert_empty s3.api_requests
  end
end
