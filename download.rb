#! /usr/bin/env ruby
require 'nokogiri'
require 'set'
require 'logger'
require 'open3'
require 'json'

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

def download_ratings(username:)
  ratings = []
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

      relurl = name.as_doc.css('.primary')[0].attr('href')
      id = relurl.split('/')[2]

      rating = rating.as_doc.css('.ratingtext')[0]&.inner_html&.to_f || 0.0
      ratings << {user_id: username, item_id: id, rating: rating}
    end
  end
  ratings
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

# TODO: @jbodah 2022-12-01: should probably just save entire result so I can filter them locally
# TODO: @jbodah 2022-12-01: is expansion? reimplements?
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

dataset = JSON.load_file 'dataset.json'
$stdin.each_line do |line|
  dataset += download_ratings(username: line.strip)
end
File.write 'dataset.json', dataset.to_json
