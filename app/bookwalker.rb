require 'aws-sdk-s3'
require 'aws-sdk-secretsmanager'
require 'date'
require 'json'
require 'mechanize'
require 'rss'

$name = ENV['NAME']

$secrets_manager = Aws::SecretsManager::Client.new
def fetch_secrets
  res = $secrets_manager.get_secret_value(secret_id: ENV.fetch('BOOKWALKER_SECRET_NAME'))
  JSON.parse(res.secret_string)
end

Book = Struct.new(:id, :url, :title, :authors, :purchase_date, keyword_init: true)

def parseBookDate(s)
  DateTime.strptime("JST #{s}", '%Z %Y/%m/%d %R')
end

$agent = Mechanize.new do |agent|
  agent.user_agent = 'bookwalker-booklist (+https://github.com/hanazuki/bookwalker-booklist)'
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

def scrape()
  $agent.get('https://bookwalker.jp/holdBooks')
  login

  books = []

  $agent.page.search('.book-item').each do |item|
    books << Book.new(
      id: (item % '.book-tl-txt a').attr('data-uuid'),
      title: (item % '.book-tl-txt a').text,
      url: (item % '.book-tl-txt a').attr('href'),
      purchase_date: parseBookDate((item % '.book-date').text),
      authors: (item / '.book-meta-item-author').map(&:text).reject(&:empty?),
    )
  end

  books
end

def generate_feed(books, acode)
  RSS::Maker.make('2.0') do |maker|
    maker.channel.title = maker.channel.description = "BOOK☆WALKER購入履歴 (#{$name})"
    maker.channel.link = 'https://example.com'

    maker.items.do_sort = true

    books.each do |book|
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

def main(*)
  books = scrape
  fail 'Something went wrong!' if books.size == 0

  $acode ||= fetch_acode

  feed = generate_feed(books, $acode)

  bucket = Aws::S3::Resource.new.bucket(ENV.fetch('BOOKWALKER_S3_BUCKET'))
  bucket.object(ENV.fetch('BOOKWALKER_S3_KEY')).put(
    acl: 'public-read',
    body: feed.to_s,
    content_type: 'application/rss+xml',
  )
end
