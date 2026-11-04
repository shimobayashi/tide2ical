require 'optparse'
require_relative 'lib/tide_calendar'

target_date = Time.now.getlocal(TideCalendar::JAPAN_OFFSET).to_date
pc = 28
hc = 9
repeat = 1

OptionParser.new do |options|
  options.on('-d', '--date DATE', 'target date') { |value| target_date = Date.iso8601(value) }
  options.on('-p', '--pc CODE', Integer, 'target prefecture code') { |value| pc = value }
  options.on('-h', '--hc CODE', Integer, 'target harbor code') { |value| hc = value }
  options.on('-r', '--repeat COUNT', Integer, 'number of 30-day requests') { |value| repeat = value }
end.parse!

puts TideCalendar.new(pc: pc, hc: hc).generate(start_date: target_date, days: repeat * 30)
