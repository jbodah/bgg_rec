#! /usr/bin/env ruby
require 'nokogiri'
require 'set'
require 'logger'
require 'open3'

class Object
  def as_node
    Node.new(self)
  end
end

class Node
  def initialize(doc)
    @doc = doc
  end

  def find(name)
    Node.new(@doc.children.find { |c| c.name == name })
  end

  def select(name)
    @doc.children.select { |c| c.name == name }.map { |doc| Node.new(doc) }
  end

  def [](name)
    @doc.attributes[name].value
  end

  def attributes
    @doc.attributes
  end

  def as_doc
    @doc
  end

  def children
    @doc.children.map { |doc| Node.new(doc) }
  end
end

BASE = "https://boardgamegeek.com"
$logger = Logger.new($stdout)
$logger.level = Logger::DEBUG

def download_plays(username:, since:)
  items_by_id = {}
  page = 1
  done = false
  until done == true
    io = curl "#{BASE}/xmlapi2/plays?username=#{username}&mindate=#{since}&page=#{page}"
    root = Nokogiri::XML(io)
    root = Node.new(root.children[0])
    plays = root.select("play")
    done = true if plays.size != 100
    page += 1
    plays.each do |play|
      item = play.find("item")
      players = play.find("players").select("player")
      my_play = players.find { |p| p["username"] == "hiimjosh" }
      id = item["objectid"]
      items_by_id[id] ||=  {plays: 0, new: 0, id: id, name: item["name"]}
      items_by_id[id][:plays] += 1
      if my_play["new"] == "1"
        items_by_id[id][:new] = 1
      end
    end
  end
  items_by_id
end

def download_ratings(username:)
  styles_by_value = {}
  items_by_id = {}
  page = 1
  done = false
  seen = Set.new
  until done == true
    io = curl "#{BASE}/collection/user/#{username}?rated=1&subtype=boardgame&page=#{page}"
    page += 1
    root = Nokogiri::HTML(io)
    el_size = root.css('.collection_objectname').size
    done = true if el_size != 300
    rows = root.css('tr').to_a.select { |x| x.attributes["id"] && x.attributes["id"].value =~ /row_/ }.map { |x| x.children.select { |x| x.name == "td" }}
    rows.each do |tds|
      nodes = tds.map(&:as_node)
      name = nodes.find { |c| c["class"].rstrip == "collection_objectname" }
      rating = nodes.find { |c| c["class"].rstrip == "collection_rating" }
      comment = nodes.find { |c| c["class"].rstrip == "collection_comment" }

      relurl = name.as_doc.css('.primary')[0].attr('href')
      id = relurl.split('/')[2]

      items_by_id[id] ||= {}
      item = items_by_id[id]
      item[:rating_value] = rating.as_doc.css('.ratingtext')[0]&.inner_html || ""

      # TODO: @jbodah 2022-11-30:
      if item[:rating_value] != ""
        style = rating.as_doc.css('.rating')[0].attr('style').split(':')[1][0..-2]
        styles_by_value[item[:rating_value]] = style
      end

      item[:comment] = comment.as_doc.css('div').find { |x| x.attr('id').start_with? 'results_comment' }.inner_html.strip.gsub('<br>', "\n")
      item[:url] = BASE + relurl
    end
  end
  [items_by_id, styles_by_value]
end

def download_thing(id:)
  thing = {}
  out = curl "#{BASE}/xmlapi2/thing?id=#{id}"
  doc = Nokogiri::HTML(out)
  thing[:id] = id
  thing[:image_id] = File.basename(doc.css('thumbnail')[0].inner_html, ".*").sub('pic', '')
  thing[:name] = doc.xpath(".//name[@type='primary']")[0].attr('value')
  thing
end

def download_things(ids:)
  out = curl "#{BASE}/xmlapi2/thing?id=#{ids.join(',')}"
  bulk = Nokogiri::HTML(out)
  bulk.css('item').map do |doc|
    thing = {}
    thing[:id] = doc.attr('id')
    # thing[:image_id] = File.basename(doc.css('thumbnail')[0].inner_html, ".*").sub('pic', '')
    thing[:name] = doc.xpath(".//name[@type='primary']")[0].attr('value')
    thing
  end
end

def run(since:)
  items_by_id = download_plays(username: "hiimjosh", since: since)
  items = items_by_id.values
  new_items = items.select { |i| i[:new] == 1 }

  items_by_id2, styles_by_value = download_ratings(username: "hiimjosh")

  items_by_id.each do |id, item|
    item.merge!(items_by_id2[id]) if items_by_id2[id]
  end

  unrated_items, rated_items = new_items.partition { |i| i[:rating_value] == "" }

  rated_items.each do |item|
    begin
      io = curl "#{BASE}/xmlapi2/thing?id=#{item[:id]}"
      image_id = File.basename(Nokogiri::HTML(io).css('thumbnail')[0].inner_html, ".*").sub('pic', '')
      item[:image_id] = image_id
    rescue => e
      puts [item[:name], e].inspect
    end
  end

  rated_items.sort_by { |i| -i[:rating_value].to_i }.each do |item|
    puts <<~EOF
    [size=12][b][thing=#{item[:id]}]#{item[:name]}[/thing] - [COLOR=#00CC00]#{item[:plays]} plays[/COLOR] - [BGCOLOR=#{styles_by_value[item[:rating_value]]}] #{item[:rating_value]} [/BGCOLOR][/b][/size]
    [imageID=#{item[:image_id]} square inline]

    #{item[:comment]}

    EOF
  end

  if unrated_items.any?
    puts "Unrated Items:"
    unrated_items.sort_by { |i| i[:name] }.each { |i| puts "* #{i[:name]} (#{i[:url]})" }
  end

  nocomment_items = rated_items.select { |x| x[:comment].empty? }
  if nocomment_items.any?
    puts "Nocomment Items:"
    nocomment_items.sort_by { |i| i[:name] }.each { |i| puts "* #{i[:name]} (#{i[:url]})" }
  end
end

def curl(url)
  backoff = 1
  loop do
    $logger.debug "making req to #{url}"
    out, _, st = Open3.capture3("curl", url, err: "/dev/null")
    if out =~ /Rate limit exceeded/
      $logger.debug "rate limit exceeded; backing off then retrying"
      sleep backoff
      backoff = backoff * 2
    elsif st.to_i != 0
      sleep backoff
    else
      return out
    end
  end
end

#run since: "2022-11-01"
