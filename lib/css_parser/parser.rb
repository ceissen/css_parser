module CssParser # :nodoc:
  # == Ruby CssParser
  #
  # Load, parse and cascade CSS rules.
  #
  # ==== Installation
  # Install the gem from RubyGems.
  #
  #   gem install css_parser
  #
  # ==== Configuration
  # [<tt>absolute_paths</tt>] Convert relative paths to absolute paths (<tt>href</tt>, <tt>src</tt> and <tt>url('')</tt>. Boolean, default is <tt>true</tt>.
  #
  # ==== Example
  #   parser = CssParser::Parser.new
  #   parser.load_file!('http://example.com/styles/style.css')
  #
  #   parser.find('#content')
  #   => 'font-size: 13px; line-height: 1.2;'
  #
  #   parser.each_selector([:screen, :handheld]) do |selector, declarations, specificity|
  #     puts "Selector: #{selector}"
  #     puts "Declarations: #{declarations}"
  #     puts "Specificity: #{specificity.to_s}"
  #   end
  #
  # ==== Credits
  # By Alex Dunae (dunae.ca, e-mail 'code' at the same domain), 2007
  class Parser
    include CssParser::Shorthand

    VERSION      = '1.0.0'
    USER_AGENT   = "Ruby CSS Parser/#{VERSION} (http://code.dunae.ca/css_parser/)"

    STRIP_CSS_COMMENTS_RX = /\/\*.*?\*\//m
    STRIP_HTML_COMMENTS_RX = /\<\!\-\-|\-\-\>/m

    # Initial parsing
    RE_AT_IMPORT_RULE = /\@import[\s]+(url\()?["']+(.[^'"]*)["']\)?([\w\s\,]*);?/i

    #--
    # RE_AT_IMPORT_RULE = Regexp.new('@import[\s]*(' + RE_STRING.to_s + ')([\w\s\,]*)[;]?', Regexp::IGNORECASE) -- should handle url() even though it is not allowed
    #++

    # CSS files in the order they were encountered
    attr_reader   :css_source    

    attr_reader   :rules

    def initialize(options = {})
      @options = {:absolute_paths => true}.merge(options)

      # array of RuleSets
      @rules = []
      
      # unprocessed blocks of CSS
      @blocks = []
      reset!
    end

    # Get declarations by selector.
    #
    # +media_types+ are optional, and can be a symbol or an array of symbols.
    # The default value is <tt>:all</tt>.
    #
    # ==== Examples
    #  find('#content')
    #  => 'font-size: 13px; line-height: 1.2;'
    #
    #  find('#content', [:screen, :handheld])
    #  => 'font-size: 13px; line-height: 1.2;'
    #
    #  find('#content', :print)
    #  => 'font-size: 11pt; line-height: 1.2;'
    #
    # Returns an array of declarations.
    def find(selector, media_types = :all)
      out = []
      each_selector(media_types) do |sel, dec, spec|
        out << dec if sel.strip == selector.strip
      end
      out
    end

    # Add a raw block of CSS.
    #
    # ==== Example
    #   css = <<-EOT
    #     body { font-size: 10pt }
    #     p { margin: 0px; }
    #     @media screen, print {
    #       body { line-height: 1.2 }
    #     }
    #   EOT
    #
    #   parser = CssParser::Parser.new
    #   parser.load_css!(css)
    def add_block!(block, options = {})
      options = {:source_uri => nil, :charset => nil}.merge(options)
      
      block = cleanup_block(block)
      
      block = convert_uris(block, options[:source_uri]) if options[:source_uri]
      
      parse_block_into_rule_sets!(block, options)
    end

    # Add a CSS rule by setting the +selectors+, +declarations+ and +media_types+.
    #
    # +media_types+ can be a symbol or an array of symbols.
    def add_rule!(selectors, declarations, media_types = :all)
      rule_set = RuleSet.new(selectors, declarations)
      add_rule_set!(rule_set, media_types)
    end

    # Add a CssParser RuleSet object.
    #
    # +media_types+ can be a symbol or an array of symbols.
    def add_rule_set!(ruleset, media_types = :all)
      raise ArgumentError unless ruleset.kind_of?(CssParser::RuleSet)

      media_types = [media_types] if media_types.kind_of?(Symbol)

      @rules << {:media_types => media_types, :rules => ruleset}
    end

    # Iterate through RuleSet objects.
    #
    # +media_types+ can be a symbol or an array of symbols.
    def each_rule_set(media_types = :all) # :yields: rule_set
      media_types = [:all] if media_types.nil?
      media_types = [media_types] if media_types.kind_of?(Symbol)

      @rules.each do |block|
        if block[:media_types].any? { |mt| media_types.include?(mt) }
          yield block[:rules]
        end
      end
    end

    # Iterate through CSS selectors.
    #
    # +media_types+ can be a symbol or an array of symbols.
    # See RuleSet#each_selector for +options+.
    def each_selector(media_types = :all, options = {}) # :yields: selectors, declarations, specificity
      each_rule_set(media_types) do |rule_set|
        rule_set.each_selector(options) do |selectors, declarations, specificity|
          yield selectors, declarations, specificity
        end
      end
    end

    # Merge declarations with the same selector.
    def compact! # :nodoc:
      compacted = []

      compacted
    end

    def parse_block_into_rule_sets!(block, options = {}) # :nodoc:
      options = {:media_types => :all}.merge(options)
      media_types = options[:media_types]

      in_declarations = false

      block_depth = 0

      # @charset is ignored for now
      in_charset = false
      in_string = false
      in_at_media_rule = false

      current_selectors = ''
      current_declarations = ''

      # TODO: this fails on '}}'
      block.scan(/((.[^\{\}"\s]*)([\{\}"\s]?))/).each do |matches|
      #block.scan(/((.[^{}"\n\r\f\s]*)[\s]|(.[^{}"\n\r\f]*)\{|(.[^{}"\n\r\f]*)\}|(.[^{}"\n\r\f]*)\"|(.*)[\s]+)/).each do |matches|
        token = matches[0]
        if token =~ /[^\/]"/ # found un-escaped double quote
          in_string = !in_string
        end


        if in_declarations
          current_declarations += token

          if token =~ /\}/ and not in_string
            current_declarations.gsub!(/\}[\s]*$/, '')
            in_declarations = false

            unless current_declarations.strip.empty?
              #puts "saving rule with #{media_types.inspect}"
              add_rule!(current_selectors, current_declarations, media_types)
            end

            current_selectors = ''
            current_declarations = ''
          end
        elsif token =~ /@media/i
          # found '@media', reset current media_types
          in_at_media_rule = true
          media_types = []
        elsif in_at_media_rule
          if token =~ /\{/
            block_depth = block_depth + 1
            in_at_media_rule = false
          else
            token.gsub!(/\,/, '')
            media_types << token.strip.downcase.to_sym
          end
        elsif in_charset or token =~ /@charset/i
          # iterate until we are out of the charset declaration
          in_charset = (token =~ /;/ ? false : true)
        else

          if token =~ /\}/ and not in_string
            block_depth = block_depth - 1
          else
            current_selectors += token
            if token =~ /\{/ and not in_string
              current_selectors.gsub!(/\{[\s]*$/, '')
              current_selectors.gsub!(/^[\s]*/, '')
              current_selectors.gsub!(/[\s]*$/, '')
              in_declarations = true
            end
          end
        end
      end
    end




    # Perform a cascade to remove redundant CSS properties according to the CSS 2.1 cascading rules 
    # (http://www.w3.org/TR/REC-CSS2/cascade.html#cascading-order).
    #
    # Takes an array of hashes or of RuleSets.  Each hash must have <tt>:specificity</tt> and <tt>:declarations</tt> defined.
    # Each declaration is processed in the order it is encountered.
    #
    # Returns a string.
    #
    # ==== Example
    #  declaration_hashes = [{:specificity => 10, :declarations => 'color: red; font: 300 italic 11px/14px verdana, helvetica, sans-serif;'},
    #                        {:specificity => 1000, :declarations => 'font-weight: normal'}]
    #
    #  fold_declarations(declaration_hashes).inspect
    #
    #  => "font-weight: normal; font-size: 11px; line-height: 14px; font-family: verdana, helvetica, sans-serif; 
    #      color: red; font-style: italic;"
    #--
    # TODO: declaration_hashes should be able to contain a RuleSet
    def fold_declarations(declaration_hashes)
      # Attempt to load folded declaration from cache
      block_hash = Digest::MD5.hexdigest(declaration_hashes.inspect)
      if folded_declaration = get_folded_declaration(block_hash)
        return folded_declaration
      end

      # Internal storage of CSS properties to keep
      properties = {}

      declaration_hashes.each do |declaration_hash|
        ruleset = RuleSet.new(nil, declaration_hash[:declarations], declaration_hash[:specificity])
        ruleset.expand_shorthand!
        specificity  = declaration_hash[:specificity]

        ruleset.each_declaration do |property, value, is_important|
          # Add the property to the list to be folded per http://www.w3.org/TR/CSS21/cascade.html#cascading-order
          if not properties.has_key?(property) or
                 is_important or # step 2
                 properties[property][:specificity] < specificity or # step 3
                 properties[property][:specificity] == specificity # step 4    
            properties[property] = {:value => value, :specificity => specificity, :is_important => is_important}            
          end
        end
      end

      combine_into_shorthand(properties)

      folded_declaration = ''

      # Rebuild the full declaration block
      properties.each do |property, details|
        folded_declaration += property.strip + ': ' + details[:value].strip + '; '
      end

      folded_declaration.strip!

      # Save to cache
      save_folded_declaration(block_hash, folded_declaration)

      folded_declaration
    end

    # Make <tt>url()</tt> links absolute.
    #
    # Takes a block of CSS and returns it with all relative URIs converted to absolute URIs.
    #
    # "For CSS style sheets, the base URI is that of the style sheet, not that of the source document."
    # per http://www.w3.org/TR/CSS21/syndata.html#uri
    #
    # Returns a string.
    #
    # ==== Example
    #  convert_uris("body { background: url('../style/yellow.png?abc=123') };", 
    #               "http://example.org/style/basic.css").inspect
    #  => "body { background: url('http://example.org/style/yellow.png?abc=123') };"
    def self.convert_uris(css, base_uri)
      out = ''
      base_uri = URI.parse(base_uri) unless base_uri.kind_of?(URI)

      out = css.gsub(URI_RX) do |s|
        uri = $1.to_s
        uri.gsub!(/["']+/, '')
        # Don't process URLs that are already absolute
        unless uri =~ /^[a-z]+\:\/\//i
          begin
            uri = base_uri.merge(uri) 
          rescue; end
        end
        "url('" + uri.to_s + "')"
      end
      out
    end

    # Calculates the specificity of a CSS selector
    # per http://www.w3.org/TR/CSS21/cascade.html#specificity
    #
    # Thanks to Rafael Salazar and Nick Fitzsimons on the css-discuss list for their help.
    #
    # Returns an integer.
    #
    # ==== Example
    #  calculate_specificity('#content div p:first-line a:link')
    #  => 114
    def self.calculate_specificity(selector)
      a = 0
      b = selector.scan(/\#/).length
      c = selector.scan(NON_ID_ATTRIBUTES_AND_PSEUDO_CLASSES_RX).length
      d = selector.scan(ELEMENTS_AND_PSEUDO_ELEMENTS_RX).length

      (a.to_s + b.to_s + c.to_s + d.to_s).to_i
    end

    # Load a remote CSS file.
    #
    # Follows <tt>@import</tt> links and loads them in order.
    #
    # Remote files are converted to UTF-8.
    def load_file!(src, base_uri = nil)

      imported_src = ''

      # Load @imported CSS
      src.scan(RE_AT_IMPORT_RULE).each do |import_rule|
        import_path = import_rule[1].to_s.gsub(/['"]*/, '').strip
        uri = URI.parse(base_uri.to_s).merge(import_path)

        media_type = import_rule[import_rule.length] ||= ''

        remote_src, remote_charset = read_remote_file(uri)
        # Recurse
        load_file!(remote_src, uri)
      end

      # Remove @import declarations
      src.gsub!(RE_AT_IMPORT_RULE, '')

      # Relative paths need to be converted here
      src = Parser.convert_uris(src, base_uri) if base_uri and @options[:absolute_paths]

      add_block!(src, :charset => charset)
    end

  protected

    # Strip comments and clean up blank lines from a block of CSS.
    #
    # Returns a string.
    def cleanup_block(block) # :nodoc:
      # Strip CSS comments
      block.gsub!(STRIP_CSS_COMMENTS_RX, '')

      # Strip HTML comments - they shouldn't really be in here but 
      # some people are just crazy...
      block.gsub!(STRIP_HTML_COMMENTS_RX, '')

      # Strip lines containing just whitespace
      block.gsub!(/^\s+$/, "")

      block
    end

    # Download a file into a string.
    #
    # Returns the file's data and character set in an array.
    def read_remote_file(uri, target_charset = 'UTF-8') # :nodoc:
      fh = open(uri, 'rb', 'User-Agent' => USER_AGENT, 'Accept-Encoding' => 'gzip')

      if fh.content_encoding.include?('gzip')
        remote_src = Zlib::GzipReader.new(fh).read
      else
        remote_src = fh.read
      end

      #puts "reading #{uri}\n  charset: #{fh.charset}\n  enc: #{fh.content_encoding}\n"

      #ic = Iconv.new('UTF-8//IGNORE', fh.charset)
      #src = ic.iconv(remote_src)

      fh.close
      return remote_src, fh.charset
    end

    # Determine is a property should overwrite an existing propery
    # per http://www.w3.org/TR/CSS21/cascade.html#cascading-order
    def should_overwrite?(existing_properties, property, specificity, is_important) # :nodoc:
       if not existing_properties.has_key?(property) or
          is_important or # step 2
          existing_properties[property][:specificity] < specificity or # step 3
          existing_properties[property][:specificity] == specificity # step 4    
        return true
      else
        return false
      end
    end

  private
    # Save a folded declaration block to the internal cache.
    def save_folded_declaration(block_hash, folded_declaration) # :nodoc:
      @folded_declaration_cache[block_hash] = folded_declaration
    end

    # Retrieve a folded declaration block from the internal cache.
    def get_folded_declaration(block_hash) # :nodoc:
      return @folded_declaration_cache[block_hash] ||= nil
    end

    def reset! # :nodoc:
      @folded_declaration_cache = {}
      @css_source = ''
      @css_rules = []
      @css_warnings = []
    end
  end
end