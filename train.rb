require 'disco'
require 'optparse'
require 'json'

options = {
  dataset: 'dataset.json',
  users: 'users.json',
  item_id_to_name: 'item_id_to_name.json',
}

OptionParser.new do |opts|
end.parse!(ARGV)

dataset = JSON.load_file(options[:dataset]).map { |row| row.map { |k, v| [k.to_sym, v] }.to_h }
evaled = eval File.read(options[:item_id_to_name])
File.write(options[:item_id_to_name], evaled.to_json)
$item_id_to_name = JSON.load_file(options[:item_id_to_name])

def cross_validate(dataset)
  pct_out = 10
  take_size = dataset.size / pct_out
  min = 0
  max = 0
  n = 1
  results = []
  while max != -1
    max += take_size
    if n == pct_out
      max = -1
    end
    n += 1
    test = dataset[min..max]
    train = dataset - test
    results << yield(train, test)
    min += take_size
  end
  results
end

def train(dataset, factors: 8, epochs: 20)
  rec = Disco::Recommender.new(factors: factors, epochs: epochs)
  rec.fit(dataset)
  rec
end

def train_and_test(dataset, factors: 8, epochs: 20)
  cross_validate(dataset) do |train_dat, test|
    rec = train(train_dat)
    zipped = test.map { |row| row[:rating] }.zip(rec.predict(test))
    Math.sqrt(zipped.map do |(actual, predict)|
      diff = actual - predict
      diff * diff
    end.sum / zipped.size)
  end
end

def translate(recs)
  recs.each { |rec| rec[:name] = $item_id_to_name[rec[:item_id]] }
end

base_dataset = dataset.shuffle
count_by_id = base_dataset.reduce({}) { |acc, row| id = row[:item_id]; acc[id] ||= 0; acc[id] +=1; acc }
highest_rating_by_id = base_dataset.reduce({}) { |acc, row| id = row[:item_id]; acc[id] ||= 0; acc[id] = [acc[id], row[:rating]].max; acc }

# [5, 6, 7, 8].each do |min_rating|
#   filtered_dataset = base_dataset.reject { |row| row[:rating] < min_rating }
#   [2, 5, 10, 15, 20, 25, 30].each do |filter|
#     filtered_dataset2 = filtered_dataset.reject { |row| count_by_id[row[:item_id]] < filter }
#     [2, 20, 80, 200, 400].each do |factor|
#       results = train_and_test(filtered_dataset2, factors: factor)
#       puts sprintf("min_rating=%d filter=%d factor=%d [min=%f, max=%f, mean=%f]", min_rating, filter, factor, results.min, results.max, results.sum/results.size.to_f)
#     end
#   end
# end

# filtered_dataset = base_dataset.reject { |row| highest_rating_by_id[row[:item_id]] < 7 || count_by_id[row[:item_id]] < 10 }
# rec = train(filtered_dataset, factors: 20)
# puts translate(rec.user_recs("hiimjosh", count: 50))
