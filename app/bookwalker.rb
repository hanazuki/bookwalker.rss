require 'aws-sdk-s3'
require 'aws-sdk-secretsmanager'
require 'date'
require 'json'
require 'mechanize'
require 'rss'

$name = ENV['NAME']

$bucket = Aws::S3::Resource.new.bucket(ENV.fetch('BOOKWALKER_S3_BUCKET'))
$prefix = ENV.fetch('BOOKWALKER_S3_KEY_PREFIX', '')


$secrets_manager = Aws::SecretsManager::Client.new
def fetch_secrets
  res = $secrets_manager.get_secret_value(secret_id: ENV.fetch('BOOKWALKER_SECRET_ARN'))
  JSON.parse(res.secret_string)
end

Book = Struct.new(:id, :url, :title, :authors, :purchase_date, keyword_init: true)

def parseBookDate(s)
  DateTime.strptime("JST #{s}", '%Z %Y/%m/%d %R')
end

$agent = Mechanize.new do |agent|
  agent.user_agent = 'bookwalker.rss (+https://github.com/hanazuki/bookwalker.rss)'
end

def login
  if form = $agent.page.form_with(id: 'loginForm')
    secrets = fetch_secrets
    form.j_username = secrets.fetch('username')
    form.j_password = secrets.fetch('password')
    form.submit
  end
end

def fetch_acode
  $agent.get('https://member.bookwalker.jp/app/03/my/profile')
  login

  $agent.page.search('#inviteId').text
end

def scrape
  $agent.get('https://bookwalker.jp/holdBooks/')
  login

  csrf_token = $agent.page.content[/window\.BW_CSRF_TOKEN.*$/][/(?<=").+(?=")/].gsub(/\\u([0-9a-f]{4})/i) { $1.hex.chr }

  $agent.post('https://bookwalker.jp/prx/holdBooks-api/hold-book-list/', {
    'backUrl' => 'https://bookwalker.jp/holdBooks/',
    'csrfToken' => csrf_token,
  })

  JSON.parse($agent.page.content)['holdBookList']['entities'].map do |item|
    Book.new(
      id: item['uuid'],
      title: item['title'],
      url: item['detailUrl'],
      purchase_date: Time.parse(item['buyTime']),
      authors: item['authors'].map {|a| a['authorName'] },
    )
  end
end

def safe?(book)
  book.url !~ /\br18\b/
end

def generate_feed(books, acode, safe: false)
  RSS::Maker.make('2.0') do |maker|
    maker.channel.title = maker.channel.description = "BOOK☆WALKER購入履歴 (#{$name})"
    maker.channel.link = 'https://example.com'

    maker.items.do_sort = true

    books.each do |book|
      next if safe && !safe?(book)

      maker.items.new_item do |item|
        item.link = acode ? "#{book.url}?acode=#{acode}" : book.url
        item.title = "#{book.title} / #{book.authors.join(', ')}"
        item.date = book.purchase_date.to_time
        item.guid.content = book.url
        item.guid.isPermaLink = true
      end
    end
  end
end

def upload_feed(name, feed)
  $bucket.object(name).put(
    acl: 'public-read',
    body: feed.to_s,
    content_type: 'application/rss+xml',
  )
end

def main(*)
  books = scrape
  fail 'Something went wrong!' if books.size == 0

  $acode ||= fetch_acode
  [
    Thread.new { upload_feed($prefix + "booklist.rss", generate_feed(books, $acode)) },
    Thread.new { upload_feed($prefix + "booklist-safe.rss", generate_feed(books, $acode, safe: true)) },
  ].map(&:value)
end

if __FILE__ == $0
  books = scrape
  acode = fetch_acode
  puts generate_feed(books, acode)
end
