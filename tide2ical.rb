require 'icalendar'
require 'open-uri'
require 'json'
require 'optparse'

# 実行オプションのデフォルト値
target_date = Time.now 
pc = 28 # 兵庫県
hc = 9 # 明石
repeat = 1 # APIから繰り返し取得する回数。3なら90日分

opt = OptionParser.new
opt.on('-d', '--date [ITEM]', 'target date') {|val|
    target_date = Time.parse(val) if val
}
opt.on('-p', '--pc [ITEM]', 'target prefecture code') {|val|
    pc = val.to_i if val
}
opt.on('-h', '--hc [ITEM]', 'target harbor code') {|val|
    hc = val.to_i if val
}
opt.on('-r', '--repeat [ITEM]', 'repeating times of totaling') {|val|
    repeat = val.to_i if val
}
opt.parse(ARGV)

calendar = Icalendar::Calendar.new
calendar.timezone do |t|
    t.tzid = 'Asia/Tokyo'
    t.standard do |s|
        s.tzoffsetfrom = '+0900'
        s.tzoffsetto   = '+0900'
        s.tzname       = 'JST'
        s.dtstart      = '19700101T000000'
    end
end

(1..repeat).each {|repeat_index|
    uri = URI.parse('https://api.tide736.net/get_tide.php')
    uri.query = URI.encode_www_form({
        'pc' => pc, # 都道府県コード
        'hc' => hc, # 港コード
        'yr' => target_date.year, # 調べたい年
        'mn' => target_date.month, # 調べたい月
        'dy' => target_date.day, # 調べたい日
        'rg' => 'month',
    })
    uri.open {|f|
        json = JSON.parse(f.read)

        events = []
        json['tide']['chart'].each {|date_str, chart|
            date = Time.parse(date_str)
            # ページングのためにtarget_dateを書き換える
            target_date = date if date > target_date
            # 日の出
            hour, min = chart['sun']['rise'].split(':').map{|e| e.to_i}
            if min >= 60 # 不思議と60分が返ってくるケースがあるようだった
                hour += min.div(60)
                min %= 60
            end
            events << {
                'summary' => '日の出',
                'dtstart' => Time.new(date.year, date.month, date.day, hour, min),
            }
            # 日の入
            hour, min = chart['sun']['set'].split(':').map{|e| e.to_i}
            if min >= 60 # 不思議と60分が返ってくるケースがあるようだった
                hour += min.div(60)
                min %= 60
            end
            events << {
                'summary' => '日の入',
                'dtstart' => Time.new(date.year, date.month, date.day, hour, min),
            }
            # 干潮
            chart['edd'].each {|edd|
                events << {
                    'summary' => "干潮 #{edd['cm']}cm",
                    'dtstart' => Time.at(edd['unix'] / 1000),
                }
            }
            # 満潮
            chart['flood'].each {|flood|
                events << {
                    'summary' => "満潮 #{flood['cm']}cm",
                    'dtstart' => Time.at(flood['unix'] / 1000),
                }
            }
        }
        # ページングの際にすでに取得しているtarget_dateは不要なので1日進める
        target_date += 60 * 60 * 24

        calendar.append_custom_property('X-WR-CALNAME;VALUE=TEXT', "#{json['tide']['port']['harbor_namej']}の潮汐表") if repeat_index == 1
        events.each {|event|
            e = Icalendar::Event.new
            e.summary = event['summary']
            e.dtstart = Icalendar::Values::DateTime.new(event['dtstart'])
            e.dtend = Icalendar::Values::DateTime.new(event['dtstart'] + 60 * 60)
            
            calendar.add_event(e)
        }
    }
}

calendar.publish
puts calendar.to_ical
