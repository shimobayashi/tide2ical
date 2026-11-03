require 'date'
require 'digest'
require 'icalendar'
require 'json'
require 'open-uri'
require 'time'

class TideCalendar
  class InvalidResponse < StandardError; end

  API_URL = 'https://api.tide736.net/get_tide.php'.freeze
  JAPAN_OFFSET = '+09:00'.freeze

  def initialize(pc:, hc:, fetcher: nil)
    @pc = Integer(pc)
    @hc = Integer(hc)
    @fetcher = fetcher || method(:fetch)
  end

  def generate(start_date:, days:)
    raise ArgumentError, 'days must be positive' unless days.positive?

    calendar = Icalendar::Calendar.new
    port_name = nil
    (0...days).step(30) do |offset|
      first_date = start_date + offset
      response = @fetcher.call(request_uri(first_date))
      validate_response(response, first_date)
      name = response.fetch('tide').fetch('port').fetch('harbor_namej')
      raise InvalidResponse, 'port name changed between requests' if port_name && port_name != name

      port_name = name
      [30, days - offset].min.times do |index|
        date = first_date + index
        chart = response.fetch('tide').fetch('chart').fetch(date.iso8601)
        append_day(calendar, date, chart)
      end
    end
    calendar.append_custom_property('X-WR-CALNAME', "#{port_name}の潮汐表")
    calendar.publish
    calendar.to_ical
  end

  private

  def request_uri(date)
    URI(API_URL).tap do |uri|
      uri.query = URI.encode_www_form(pc: @pc, hc: @hc, yr: date.year,
                                     mn: date.month, dy: date.day, rg: 'month')
    end
  end

  def fetch(uri)
    uri.open(open_timeout: 10, read_timeout: 20) { |file| JSON.parse(file.read) }
  end

  def validate_response(response, date)
    raise InvalidResponse, 'API returned an error' unless [1, '1'].include?(response['status'])

    tide = response.fetch('tide')
    port = tide.fetch('port')
    unless Integer(port.fetch('prefecture_code')) == @pc && Integer(port.fetch('harbor_code')) == @hc
      raise InvalidResponse, 'API returned a different port'
    end
    expected_dates = 30.times.map { |index| (date + index).iso8601 }
    unless tide.fetch('chart').keys.sort == expected_dates
      raise InvalidResponse, 'API did not return all 30 requested dates'
    end
    raise InvalidResponse, 'API returned an empty port name' if port.fetch('harbor_namej').to_s.empty?
  end

  def append_day(calendar, date, chart)
    { 'rise' => '日の出', 'set' => '日の入' }.each do |kind, summary|
      clock = chart.fetch('sun').fetch(kind)
      raise InvalidResponse, 'invalid sunrise or sunset' unless /\A\d{1,2}:\d{2}\z/.match?(clock)

      hour, minute = clock.split(':').map(&:to_i)
      unless hour < 24 && minute <= 60 && hour * 60 + minute < 1440
        raise InvalidResponse, 'sunrise or sunset is outside its date'
      end
      # API が返す「60分」も日本時間の午前0時からの秒数として扱う。
      time = Time.new(date.year, date.month, date.day, 0, 0, 0, JAPAN_OFFSET) + hour * 3600 + minute * 60
      append_event(calendar, date, kind, 0, summary, time)
    end
    { 'edd' => '干潮', 'flood' => '満潮' }.each do |kind, label|
      tides = chart.fetch(kind)
      raise InvalidResponse, 'invalid tide list' unless tides.is_a?(Array)

      tides.sort_by { |tide| Integer(tide.fetch('unix')) }.each_with_index do |tide, index|
        time = Time.at(Rational(Integer(tide.fetch('unix')), 1000)).getlocal(JAPAN_OFFSET)
        raise InvalidResponse, 'tide is outside its date' unless time.to_date == date

        height = tide.fetch('cm')
        raise InvalidResponse, 'invalid tide height' unless height.is_a?(Numeric) && height.finite?

        append_event(calendar, date, kind, index, "#{label} #{height}cm", time)
      end
    end
  end

  def append_event(calendar, date, kind, index, summary, time)
    event = Icalendar::Event.new
    # 時刻や潮位が修正されても、同じ日の同じ種類の予定として更新できるようにする。
    event.uid = Digest::SHA256.hexdigest("#{API_URL}/#{@pc}/#{@hc}/#{date}/#{kind}/#{index}")
    event.summary = summary
    event.dtstart = Icalendar::Values::DateTime.new(time.utc)
    event.dtend = Icalendar::Values::DateTime.new((time + 3600).utc)
    calendar.add_event(event)
  end
end
