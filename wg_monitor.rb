#!/usr/bin/env ruby
require 'net/http'
require 'uri'
require 'nokogiri'
require 'json'
require 'fileutils'
require 'zlib'
require 'stringio'

# Configuration
CACHE_FILE = File.expand_path('.wg_monitor_cache.json')
# Just use the distinctive part of the street name - partial, case-insensitive matching
TARGET_STREETS = [
  'Oder',
  'Warthe',
  'Netze',
  'Emser',
  'Siegfried',
  'Leine',
  'Oker',
  'Lichtenrader',
  'Schillerpromenade',
  'Weise',
  'Aller',
  'Kienitzer',
  'Herrfurth',
  'Selchower',
  'Mahlower',
  'Fontane',
  'Karlsgarten',
  'Mariendorfer'
]
# Districts to search (add more as needed)
SEARCH_DISTRICTS = [
  'Neukölln',
  # 'Kreuzberg',
  # 'Friedrichshain',
  # 'Prenzlauer Berg',
  # Add more districts from: Charlottenburg, Hellersdorf, Hohenschönhausen,
  # Köpenick, Lichtenberg, Marzahn, Mitte, Pankow, Reinickendorf, Schöneberg,
  # Spandau, Steglitz, Tempelhof, Tiergarten, Treptow, Wedding, Weißensee,
  # Wilmersdorf, Zehlendorf, Potsdam, Umland
]
REQUIRED_KEYWORD = 'dauerhaft'  # Must appear in the WG detail page

class WGMonitor
  def initialize
    @cache = load_cache
  end

  def run
    all_keyword_matches = []

    SEARCH_DISTRICTS.each do |district|
      puts "\n🔍 Searching for WGs in #{district}..."

      html = fetch_results(district)
      listings = parse_listings(html)

      street_matches = filter_by_streets(listings)
      puts "   Found #{street_matches.length} listings on target streets"

      # Check which street matches are new BEFORE fetching detail pages
      new_street_matches = find_new_listings(street_matches)
      puts "   Found #{new_street_matches.length} NEW listings on target streets"

      if new_street_matches.empty?
        puts "   ✓ No new listings in #{district}"
        next
      end

      # Only check detail pages for NEW listings
      puts "   Checking detail pages for '#{REQUIRED_KEYWORD}'..."
      keyword_matches = filter_by_keyword(new_street_matches)
      puts "   Found #{keyword_matches.length} listings with '#{REQUIRED_KEYWORD}'"

      # Update cache with ALL new street matches (not just keyword ones)
      # This prevents re-checking the same listings every time
      update_cache(new_street_matches)

      all_keyword_matches.concat(keyword_matches)
    end

    if all_keyword_matches.any?
      puts "\n🎉 Found #{all_keyword_matches.length} NEW listing(s) with '#{REQUIRED_KEYWORD}' across all districts!"
      all_keyword_matches.each do |listing|
        puts "\n  ✨ NEW: #{listing[:street]} - #{listing[:price]} - #{listing[:size]} - #{listing[:wg_type]}"
        puts "     Available: #{listing[:available]}"
        puts "     Link: #{listing[:detail_url]}"
      end

      # Open each new match in Firefox
      open_matches_in_firefox(all_keyword_matches)
    else
      puts "\n✓ No new listings with '#{REQUIRED_KEYWORD}' found in any district"
    end
  end

  private

  def decompress_response(response)
    if response['content-encoding'] == 'gzip'
      gz = Zlib::GzipReader.new(StringIO.new(response.body))
      gz.read
    else
      response.body
    end
  end

  def fetch_results(district)
    # Step 1: Visit the search form page (optional, but mimics real browser)
    form_uri = URI('http://wg-company.de/cgi-bin/seite?st=1&mi=10&li=100')
    http = Net::HTTP.new(form_uri.host, form_uri.port)

    form_request = Net::HTTP::Get.new(form_uri.request_uri)
    form_request['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0'
    form_request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    form_request['Accept-Language'] = 'en-US,en;q=0.5'
    form_request['Accept-Encoding'] = 'gzip, deflate'

    form_response = http.request(form_request)
    cookies = form_response.get_fields('set-cookie')

    # Step 2: Submit the search
    search_uri = URI('http://wg-company.de/cgi-bin/zquery.pl')

    search_request = Net::HTTP::Post.new(search_uri.path)
    search_request['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0'
    search_request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    search_request['Accept-Language'] = 'en-US,en;q=0.5'
    search_request['Accept-Encoding'] = 'gzip, deflate'
    search_request['Content-Type'] = 'application/x-www-form-urlencoded'
    search_request['Origin'] = 'http://wg-company.de'
    search_request['Connection'] = 'keep-alive'
    search_request['Referer'] = 'http://wg-company.de/cgi-bin/seite?st=1&mi=10&li=100'
    search_request['Cookie'] = cookies.join('; ') if cookies
    search_request['Upgrade-Insecure-Requests'] = '1'

    # URL encode the district name using ISO-8859-15 encoding
    encoded_district = URI.encode_www_form_component(district.encode('ISO-8859-15'))
    search_request.body = "st=1&c=&a=&l=&e=#{encoded_district}&m=&o=&sort=doe"

    search_response = http.request(search_request)
    body = decompress_response(search_response)
    
    # Convert from ISO-8859-15 to UTF-8
    body.encode('UTF-8', 'ISO-8859-15', invalid: :replace, undef: :replace)
  end

  def fetch_detail_page(wg_id)
    uri = URI("http://wg-company.de/cgi-bin/wg.pl?st=1&function=wgzeigen&wg=#{wg_id}")
    http = Net::HTTP.new(uri.host, uri.port)

    request = Net::HTTP::Get.new(uri.request_uri)
    request['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0'
    request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    request['Accept-Language'] = 'en-US,en;q=0.5'
    request['Accept-Encoding'] = 'gzip, deflate'

    response = http.request(request)
    body = decompress_response(response)
    
    # Convert from ISO-8859-15 to UTF-8
    body.encode('UTF-8', 'ISO-8859-15', invalid: :replace, undef: :replace)
  rescue => e
    puts "  ⚠️  Error fetching detail page for #{wg_id}: #{e.message}"
    nil
  end

  def parse_listings(html)
    doc = Nokogiri::HTML(html)
    listings = []
    
    # Each listing is in a <tr> with specific structure
    doc.css('table tr').each do |row|
      cells = row.css('td')
      next if cells.length < 7  # Skip header/non-data rows
      
      # Extract data from cells
      number = cells[0].text.strip.gsub('.', '')
      district = cells[1].text.strip
      street_link = cells[2].css('a').first
      
      next unless street_link
      
      street = street_link.text.strip
      href = street_link['href']
      wg_id = href&.match(/wg=([^&]+)/)&.[](1)
      detail_url = "http://wg-company.de#{href}" if href
      wg_type = cells[3].text.strip
      price = cells[4].text.strip
      size = cells[5].text.strip
      available = cells[6].text.strip
      
      listings << {
        number: number.to_i,
        district: district,
        street: street,
        wg_id: wg_id,
        detail_url: detail_url,
        wg_type: wg_type,
        price: price,
        size: size,
        available: available
      }
    end
    
    listings
  end

  def filter_by_streets(listings)
    listings.select do |listing|
      street_normalized = listing[:street].downcase
      TARGET_STREETS.any? do |target|
        street_normalized.include?(target.downcase)
      end
    end
  end

  def filter_by_keyword(listings)
    listings.select do |listing|
      print "  Checking #{listing[:street]}... "
      
      detail_html = fetch_detail_page(listing[:wg_id])
      
      if detail_html.nil?
        puts "❌ (failed to fetch)"
        next false
      end
      
      # Case-insensitive search for the keyword
      contains_keyword = detail_html.downcase.include?(REQUIRED_KEYWORD.downcase)
      
      if contains_keyword
        puts "✓ (contains '#{REQUIRED_KEYWORD}')"
      else
        puts "✗ (no '#{REQUIRED_KEYWORD}')"
      end
      
      # Add a small delay to be respectful to the server
      sleep 0.5
      
      contains_keyword
    end
  end

  def find_new_listings(current_matches)
    cached_ids = @cache['seen_wg_ids'] || []
    
    current_matches.select do |listing|
      !cached_ids.include?(listing[:wg_id])
    end
  end

  def update_cache(current_matches)
    existing_ids = @cache['seen_wg_ids'] || []
    new_ids = current_matches.map { |l| l[:wg_id] }
    @cache['seen_wg_ids'] = (existing_ids + new_ids).uniq
    @cache['last_check'] = Time.now.to_s
    save_cache
  end

  def load_cache
    if File.exist?(CACHE_FILE)
      JSON.parse(File.read(CACHE_FILE))
    else
      { 'seen_wg_ids' => [], 'last_check' => nil }
    end
  end

  def save_cache
    File.write(CACHE_FILE, JSON.pretty_generate(@cache))
  end

  def open_matches_in_firefox(matches)
    return if matches.empty?
    
    puts "\n🌐 Opening #{matches.length} new listing(s) in Firefox..."
    
    matches.each do |listing|
      url = listing[:detail_url]
      puts "   Opening: #{url}"
      
      # Detect OS and open Firefox
      success = case RbConfig::CONFIG['host_os']
      when /darwin/i  # macOS
        system("open -a Firefox '#{url}'")
      when /linux/i   # Linux
        system("firefox '#{url}' > /dev/null 2>&1 &")
      when /mswin|mingw|cygwin/i  # Windows
        system("start firefox '#{url}'")
      else
        puts "⚠️  Could not detect OS. Please open: #{url}"
        false
      end
      
      puts "   #{success ? '✓' : '✗'} Command executed"
      
      # Small delay between opening tabs to avoid overwhelming the browser
      sleep 1 if matches.length > 1
    end
  end
end

# Run the monitor
monitor = WGMonitor.new
monitor.run
