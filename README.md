# tide2ical

[日本沿岸 736 港の潮汐表 \- tide736\.net](https://tide736.net/)の API を叩いて日本の潮汐表を iCal 形式で出力するスクリプトです。

## Usage

```
bundle install
bundle exec ruby tide2ical.rb --pc 28 --hc 9 --date "2022-02-01" --repeat 3 > tide.ics
```

これで 90 日分の兵庫県明石の潮汐表が tide.ics に出力されます。

- pc や hc に何を指定するかは[日本沿岸 736 港の潮汐表 \- tide736\.net](https://tide736.net/)を参照してください
- repeat は 30 日分を何回繰り返して取得したいか指定してください
