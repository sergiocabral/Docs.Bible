# frozen_string_literal: true

require 'asciidoctor'
require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'set'
require 'tmpdir'
require 'unicode_normalize/normalize'
require 'yaml'

module DocsRag
  SCHEMA_VERSION = 1
  NORMALIZATION_VERSION = 1
  GENERATOR_NAME = 'docs-rag'
  GENERATOR_VERSION = '1.0.1'
  SERIALIZATION = 'jcs-rfc8785'
  PORTABLE_KEY = /\A[A-Za-z0-9._-]+\z/
  FAMILY_KIND = {
    'book' => 'publication',
    'bible' => 'translation',
    'jw' => 'publication',
    'notes' => 'collection'
  }.freeze

  class Error < StandardError; end

  Unit = Struct.new(
    :kind,
    :text,
    :heading_path,
    :anchor,
    :section_anchor,
    :line,
    :verse_start,
    :verse_end,
    :paragraph_start,
    :paragraph_end,
    :source_page_start,
    :source_page_end,
    keyword_init: true
  )

  Corpus = Struct.new(
    :id,
    :publication,
    :edition,
    :module_name,
    :kind,
    :title,
    :label,
    :language,
    :source_order,
    :publication_data,
    :edition_data,
    :pages,
    :source_paths,
    keyword_init: true
  )

  module Canonical
    module_function

    # The contract currently emits only strings, integers, booleans, null,
    # arrays, and objects with ASCII schema keys. Sorting those keys by UTF-8
    # bytes is therefore equivalent to RFC 8785's UTF-16 ordering.
    def normalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort_by(&:b).to_h do |key|
          source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          [key, normalize(value.fetch(source_key))]
        end
      when Array
        value.map { |item| normalize(item) }
      when String
        value.unicode_normalize(:nfc)
      when Integer, TrueClass, FalseClass, NilClass
        value
      else
        raise Error, "unsupported canonical JSON value: #{value.class}"
      end
    end

    def dump(value)
      JSON.generate(normalize(value), ascii_only: false)
    end
  end

  module Text
    PORTUGUESE_STOP_WORDS = %w[
      a ao aos aquela aquelas aquele aqueles aquilo as até com como da das de dela delas dele deles
      depois do dos e ela elas ele eles em entre era essa essas esse esses esta estas este estes eu
      foi foram há isso isto já lhe lhes mais mas me mesmo minha minhas meu meus muito na nas não no
      nos nós o os ou para pela pelas pelo pelos por porque qual quando que quem se sem ser seu seus
      sua suas também tem uma umas um uns você vocês
    ].to_set.freeze
    ENGLISH_STOP_WORDS = %w[
      a about after again all also am an and any are as at be because been before being between both
      but by can could did do does doing down during each few for from further had has have having he
      her here hers herself him himself his how i if in into is it its itself just me more most my
      myself no nor not now of off on once only or other our ours ourselves out over own same she
      should so some such than that the their theirs them themselves then there these they this those
      through to too under until up very was we were what when where which while who whom why will
      with would you your yours yourself yourselves
    ].to_set.freeze

    module_function

    def normalize(value)
      value.to_s
        .encode('UTF-8')
        .unicode_normalize(:nfc)
        .gsub("\r\n", "\n")
        .gsub("\r", "\n")
        .lines
        .map(&:rstrip)
        .join("\n")
        .gsub(/\n{3,}/, "\n\n")
        .strip
    end

    def visible_html(value)
      html = value.to_s
        .gsub(/<br\s*\/?\s*>/i, "\n")
        .gsub(%r{</(?:p|li|tr|td|th|div|blockquote|pre|h[1-6])>}i, "\n")
        .gsub(/<[^>]+>/, ' ')
      normalize(CGI.unescapeHTML(html).gsub(/[ \t\f\v]+/, ' ').gsub(/ *\n */, "\n"))
    end

    def word_count(value)
      normalize(value).split(/\p{Space}+/u).reject(&:empty?).length
    end

    def char_count(value)
      normalize(value).each_codepoint.count
    end

    def sentences(value)
      normalized = normalize(value)
      return [] if normalized.empty?

      normalized
        .split(/(?<=[.!?…])\p{Space}+(?=[\p{L}\p{N}"“‘])/u)
        .map { |sentence| normalize(sentence) }
        .reject(&:empty?)
    end

    def truncate_words(value, maximum)
      words = normalize(value).split(/\p{Space}+/u)
      return words.join(' ') if words.length <= maximum

      "#{words.first(maximum).join(' ')}…"
    end

    def slug(value)
      result = value.to_s
        .unicode_normalize(:nfkd)
        .gsub(/\p{Mn}/u, '')
        .downcase
        .gsub(/[^a-z0-9]+/, '-')
        .gsub(/\A-+|-+\z/, '')
      result.empty? ? 'section' : result
    end

    def topics(value, language, limit: 12)
      stop_words = language.to_s.downcase.start_with?('pt') ? PORTUGUESE_STOP_WORDS : ENGLISH_STOP_WORDS
      positions = {}
      counts = Hash.new(0)
      normalize(value).downcase.scan(/[\p{L}][\p{L}\p{Mn}'’_-]{2,}/u).each_with_index do |word, index|
        term = word.gsub(/\A['’_-]+|['’_-]+\z/, '')
        next if term.length < 3 || stop_words.include?(term)

        positions[term] ||= index
        counts[term] += 1
      end
      counts.keys
        .sort_by { |term| [-counts.fetch(term), positions.fetch(term), term.b] }
        .first(limit)
    end
  end

  module Identifiers
    UNRESERVED = /[A-Za-z0-9\-._~]/
    module_function

    def encode_segment(value)
      value.to_s.encode('UTF-8').bytes.map do |byte|
        character = byte.chr(Encoding::UTF_8)
        character.match?(UNRESERVED) ? character : format('%%%02X', byte)
      end.join
    end

    def encode_path(value)
      value.to_s.split('/', -1).map { |segment| encode_segment(segment) }.join('/')
    end

    def document(corpus_id, source_key)
      "document:#{encode_path("#{corpus_id}/#{source_key}")}"
    end

    def chunk(corpus_id, source_key, section_key, ordinal)
      "chunk:#{encode_path("#{corpus_id}/#{source_key}")}##{encode_segment(section_key)}-#{format('%04d', ordinal)}"
    end

    def summary(scope, corpus_id, source_key = nil, section_key = nil)
      suffix = source_key ? "/#{encode_path(source_key)}" : ''
      fragment = section_key ? "##{encode_segment(section_key)}" : ''
      "summary:#{scope}/#{encode_path(corpus_id)}#{suffix}#{fragment}"
    end
  end

  module Hashing
    module_function

    def sha256_bytes(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def canonical(value)
      sha256_bytes(Canonical.dump(value).encode('UTF-8'))
    end

    def file_set(entries, normalize_text: false)
      digest = Digest::SHA256.new
      entries.sort_by { |path, _bytes| path.b }.each do |path, bytes|
        content = normalize_text ? "#{Text.normalize(bytes.force_encoding('UTF-8'))}\n".encode('UTF-8') : bytes
        digest.update(path.encode('UTF-8'))
        digest.update("\0")
        digest.update(content)
        digest.update("\0")
      end
      "sha256:#{digest.hexdigest}"
    end

    def evidence(chunks: [], summaries: [])
      records = chunks.map do |chunk|
        {
          'id' => chunk.fetch('id'),
          'contentHash' => chunk.fetch('contentHash'),
          'headingPath' => chunk.fetch('headingPath'),
          'source' => chunk.fetch('source')
        }
      end
      records.concat summaries.map { |summary| { 'id' => summary.fetch('id'), 'sourceDigest' => summary.fetch('sourceDigest') } }
      sha256_bytes(records.map { |record| Canonical.dump(record) }.join("\n").encode('UTF-8'))
    end
  end

  class Repository
    attr_reader :root, :metadata, :antora, :repository_name, :family

    def initialize(root = Dir.pwd)
      @root = Pathname.new(root).expand_path
      @metadata = load_yaml('asciidoctor/publication.yml')
      @antora = load_yaml('antora.yml')
      @repository_name = discover_repository_name
      @family = discover_family
    end

    def discover_corpora
      corpora = []
      if metadata.key?('publications')
        metadata.fetch('publications').each do |publication_key, publication|
          validate_key!(publication_key, 'publication')
          publication.fetch('editions').each do |edition_key, edition|
            corpora << build_corpus(publication_key, publication, edition_key, edition)
          end
        end
      elsif metadata.key?('editions')
        publication = metadata.reject { |key, _value| key == 'editions' }
        metadata.fetch('editions').each do |edition_key, edition|
          corpora << build_corpus('default', publication, edition_key, edition)
        end
      else
        raise Error, 'asciidoctor/publication.yml must define publications or editions'
      end
      raise Error, 'no RAG corpus was discovered' if corpora.empty?

      corpora
    end

    def relative(path)
      Pathname.new(path).expand_path.relative_path_from(root).to_s.tr('\\', '/')
    rescue ArgumentError
      raise Error, "path escapes repository: #{path}"
    end

    def absolute(relative_path)
      candidate = root.join(relative_path).cleanpath
      relative(candidate)
      candidate
    end

    def normalized_source_bytes(relative_path)
      path = absolute(relative_path)
      raw = File.binread(path)
      text = raw.sub(/\A\xEF\xBB\xBF/n, '').force_encoding('UTF-8')
      raise Error, "source is not valid UTF-8: #{relative_path}" unless text.valid_encoding?

      "#{Text.normalize(text)}\n".encode('UTF-8')
    end

    def source_digest(paths)
      entries = paths.to_a.uniq.map { |path| [path, normalized_source_bytes(path)] }
      Hashing.file_set(entries, normalize_text: false)
    end

    private

    def load_yaml(relative_path)
      path = absolute(relative_path)
      raise Error, "missing required file: #{relative_path}" unless path.file?

      YAML.safe_load_file(path, aliases: false) || {}
    rescue Psych::Exception => error
      raise Error, "invalid YAML in #{relative_path}: #{error.message}"
    end

    def discover_repository_name
      output, status = Open3.capture2e('git', '-C', root.to_s, 'config', '--get', 'remote.origin.url')
      raise Error, 'remote.origin.url is missing or ambiguous' unless status.success?

      remote = output.strip
      name = remote.sub(%r{/+\z}, '').split(/[\/:]/).last.to_s.sub(/\.git\z/i, '')
      raise Error, 'could not derive repository from remote.origin.url' if name.empty?

      name
    end

    def discover_family
      match = repository_name.match(/\ADocs\.(Book|Bible|JW|Notes)(?:\.|\z)/)
      raise Error, "unsupported Docs.* repository family: #{repository_name}" unless match

      match[1].downcase
    end

    def validate_key!(key, label)
      raise Error, "invalid portable #{label} key: #{key}" unless key.to_s.match?(PORTABLE_KEY)
    end

    def build_corpus(publication_key, publication, edition_key, edition)
      validate_key!(edition_key, 'edition')
      module_name = edition.fetch('module', edition_key).to_s
      validate_key!(module_name, 'module')
      module_path = root.join('modules', module_name)
      raise Error, "edition module does not exist: #{module_name}" unless module_path.directory?

      title = edition['title'].to_s.strip
      language = edition['lang'].to_s.strip
      raise Error, "edition #{edition_key} has no title" if title.empty?
      raise Error, "edition #{edition_key} has no lang" if language.empty?

      source_order = source_order_for(publication, module_name)
      attributes = edition.fetch('attributes', {}).transform_keys(&:to_s).transform_values(&:to_s)
      attributes['edition-module'] = module_name
      pages = []
      sources = Set.new(%w[asciidoctor/publication.yml antora.yml])
      if source_order
        scan_includes(absolute(source_order), attributes, sources, pages, discover_pages: true, stack: [])
      else
        discover_from_nav(module_name, sources, pages)
      end
      pages.uniq!
      raise Error, "corpus #{publication_key}/#{edition_key} has no pages" if pages.empty?
      pages.each do |source_path|
        page_module = source_path.match(%r{\Amodules/([^/]+)/pages/})&.[](1)
        next if page_module == module_name
        next if page_module == 'ROOT' && root_page_included?(absolute(source_path))

        raise Error, "page #{source_path} is outside modules/#{module_name}/pages/"
      end

      kind = if publication['rag_kind']
               publication.fetch('rag_kind').to_s
             elsif family == 'jw' && publication_key == 'edition-comparison'
               'analysis'
             else
               FAMILY_KIND.fetch(family)
             end
      raise Error, "invalid corpus kind #{kind}" unless %w[publication translation collection analysis].include?(kind)

      Corpus.new(
        id: "#{publication_key}/#{edition_key}",
        publication: publication_key.to_s,
        edition: edition_key.to_s,
        module_name: module_name,
        kind: kind,
        title: title,
        label: edition['label'].to_s.strip.empty? ? nil : edition['label'].to_s,
        language: language,
        source_order: source_order,
        publication_data: publication,
        edition_data: edition,
        pages: pages,
        source_paths: sources
      )
    end

    def source_order_for(publication, module_name)
      candidates = []
      candidates << "asciidoctor/#{publication.fetch('contents')}" if publication['contents']
      candidates << "asciidoctor/contents/#{module_name}.adoc" if family == 'notes'
      candidates << 'asciidoctor/contents.adoc'
      candidates.find { |path| absolute(path).file? }
    end

    def scan_includes(path, inherited_attributes, sources, pages, discover_pages:, stack:)
      relative_path = relative(path)
      raise Error, "include cycle: #{(stack + [relative_path]).join(' -> ')}" if stack.include?(relative_path)
      raise Error, "included file does not exist: #{relative_path}" unless path.file?

      sources << relative_path
      attributes = inherited_attributes.dup
      active_stack = [true]
      normalized_source(path).lines.each do |line|
        stripped = line.strip
        if (match = stripped.match(/\Aifdef::([^\[]+)\[\]\z/))
          active_stack << (active_stack.last && attribute_condition?(attributes, match[1], expected: true))
          next
        elsif (match = stripped.match(/\Aifndef::([^\[]+)\[\]\z/))
          active_stack << (active_stack.last && attribute_condition?(attributes, match[1], expected: false))
          next
        elsif stripped.match?(/\Aendif::[^\[]*\[\]\z/)
          raise Error, "unmatched endif in #{relative_path}" if active_stack.length == 1
          active_stack.pop
          next
        end
        next unless active_stack.last

        if (match = line.match(/\A:([^:!]+):\s*(.*?)\s*\z/))
          attributes[match[1]] = substitute_attributes(match[2], attributes)
          next
        elsif (match = line.match(/\A:([^:]+)!:\s*\z/))
          attributes.delete(match[1])
          next
        end

        match = line.match(/^\s*include::([^\[]+)\[[^\]]*\]/)
        next unless match

        target = substitute_attributes(match[1].strip, attributes)
        next if target.include?('{')

        included = Pathname.new(File.expand_path(target, path.dirname)).cleanpath
        included_relative = relative(included)
        raise Error, "included file does not exist: #{included_relative}" unless included.file?

        page_match = included_relative.match(%r{\Amodules/([^/]+)/pages/(.+\.adoc)\z})
        if discover_pages && page_match && File.basename(included_relative) == '_master.adoc'
          scan_includes(included, attributes, sources, pages, discover_pages: true, stack: stack + [relative_path])
        elsif discover_pages && page_match
          module_name = page_match[1]
          if module_name == 'ROOT'
            pages << included_relative if root_page_included?(included)
          else
            pages << included_relative
          end
          scan_includes(included, attributes, sources, pages, discover_pages: false, stack: stack + [relative_path])
        else
          scan_includes(
            included,
            attributes,
            sources,
            pages,
            discover_pages: discover_pages && !page_match,
            stack: stack + [relative_path]
          )
        end
      end
      raise Error, "unclosed conditional in #{relative_path}" unless active_stack.length == 1
    end

    def normalized_source(path)
      raw = File.binread(path).sub(/\A\xEF\xBB\xBF/n, '').force_encoding('UTF-8')
      raise Error, "source is not valid UTF-8: #{relative(path)}" unless raw.valid_encoding?

      Text.normalize(raw)
    end

    def attribute_condition?(attributes, expression, expected:)
      names = expression.split(/[,+]/).map(&:strip)
      present = if expression.include?('+')
                  names.all? { |name| attributes.key?(name) }
                else
                  names.any? { |name| attributes.key?(name) }
                end
      expected ? present : !present
    end

    def substitute_attributes(value, attributes)
      previous = nil
      result = value.to_s
      10.times do
        break if result == previous
        previous = result
        result = result.gsub(/\{([^}]+)\}/) { |match| attributes.fetch(Regexp.last_match(1), match) }
      end
      result
    end

    def root_page_included?(path)
      normalized_source(path).match?(/^:page-rag-include:\s*$/)
    end

    def discover_from_nav(module_name, sources, pages)
      nav_entries = Array(antora['nav'])
      nav_paths = nav_entries.filter_map do |entry|
        value = entry.to_s
        next unless value.include?("modules/#{module_name}/") || value.include?('modules/ROOT/')
        value
      end
      nav_paths = ["modules/#{module_name}/nav.adoc"] if nav_paths.empty? && root.join('modules', module_name, 'nav.adoc').file?
      nav_paths.each do |nav_path|
        sources << nav_path
        normalized_source(absolute(nav_path)).scan(/xref:([^\[]+)\[[^\]]*\]/).flatten.each do |target|
          target = target.split('#', 2).first
          target = target.split(':').last if target.include?(':')
          candidate = "modules/#{module_name}/pages/#{target}"
          pages << candidate if absolute(candidate).file?
        end
      end
    end
  end

  class SourcePages
    def initialize(path)
      current = nil
      @by_line = {}
      File.readlines(path, encoding: 'bom|utf-8').each_with_index do |line, index|
        current = Regexp.last_match(1).to_i if line.match(/anchor:source-page-(\d+)\[\]/)
        @by_line[index + 1] = current
      end
    end

    def at(line)
      @by_line[line.to_i]
    end
  end

  class Extractor
    SKIPPED_ROLES = %w[source-reference pull-quote bible-navigation].to_set.freeze

    attr_reader :family, :corpus, :document, :path, :source_pages

    def initialize(family:, corpus:, document:, path:)
      @family = family
      @corpus = corpus
      @document = document
      @path = path
      @source_pages = SourcePages.new(path)
    end

    def extract
      case family
      when 'bible' then extract_bible
      when 'jw' then extract_jw
      else extract_common
      end
    end

    private

    def extract_common
      units = []
      headings = [document.doctitle.to_s]
      document.blocks.each { |block| common_block(block, headings, nil, units) }
      units.reject { |unit| unit.text.empty? }
    end

    def common_block(block, headings, section_anchor, units)
      return if skip_block?(block)

      case block.context
      when :section
        title = Text.normalize(block.title)
        next_headings = headings + [title]
        explicit = explicit_anchor(block.id)
        block.blocks.each { |child| common_block(child, next_headings, explicit, units) }
      when :preamble, :open
        block.blocks.each { |child| common_block(child, headings, section_anchor, units) }
      when :paragraph
        add_unit(units, block, 'prose', visible_node(block), headings, section_anchor)
      when :ulist, :olist, :dlist
        add_unit(units, block, 'list', visible_node(block), headings, section_anchor)
      when :table
        table_units(block, headings, section_anchor).each { |unit| units << unit }
      when :quote, :verse
        add_unit(units, block, 'quote', visible_node(block), headings, section_anchor)
      when :admonition
        add_unit(units, block, 'admonition', visible_node(block), headings, section_anchor)
      when :listing, :literal
        add_unit(units, block, 'code', Text.normalize(block.source), headings, section_anchor)
      when :image
        description = [block.title, block.attr('alt')].compact.map { |value| Text.normalize(value) }.reject(&:empty?).uniq.join(' — ')
        add_unit(units, block, 'image-description', description, headings, section_anchor)
      when :thematic_break, :page_break
        nil
      else
        if block.respond_to?(:blocks) && !block.blocks.empty?
          block.blocks.each { |child| common_block(child, headings, section_anchor, units) if child.respond_to?(:context) }
        else
          add_unit(units, block, 'prose', visible_node(block), headings, section_anchor)
        end
      end
    end

    def extract_bible
      return [] if File.basename(path) == 'index.adoc'

      units = []
      state = { current: nil }
      headings = [document.doctitle.to_s]
      document.blocks.each { |block| bible_block(block, headings, nil, units, state) }
      units
    end

    def bible_block(block, headings, section_anchor, units, state)
      return if skip_block?(block)

      case block.context
      when :section
        state[:current] = nil
        block.blocks.each { |child| bible_block(child, headings + [Text.normalize(block.title)], explicit_anchor(block.id), units, state) }
      when :preamble, :open
        block.blocks.each { |child| bible_block(child, headings, section_anchor, units, state) }
      when :paragraph
        text = visible_node(block)
        verse = verse_number(block.id, text)
        if verse
          unit = build_unit(block, 'verse-range', text, headings, section_anchor)
          unit.verse_start = verse
          unit.verse_end = verse
          units << unit
          state[:current] = unit
        elsif state[:current]
          append_to_unit(state[:current], text, block)
        elsif !text.empty?
          units << build_unit(block, 'verse-range', text, headings, section_anchor)
          state[:current] = units.last
        end
      when :ulist, :olist, :dlist, :admonition, :quote, :verse, :table
        text = visible_node(block)
        if state[:current]
          append_to_unit(state[:current], text, block)
        elsif !text.empty?
          units << build_unit(block, 'verse-range', text, headings, section_anchor)
          state[:current] = units.last
        end
      else
        block.blocks.each { |child| bible_block(child, headings, section_anchor, units, state) if child.respond_to?(:context) } if block.respond_to?(:blocks)
      end
    end

    def extract_jw
      units = []
      state = { current: nil }
      headings = [document.doctitle.to_s]
      document.blocks.each { |block| jw_block(block, headings, nil, units, state) }
      units
    end

    def jw_block(block, headings, section_anchor, units, state)
      return if skip_block?(block)

      case block.context
      when :section
        state[:current] = nil
        block.blocks.each { |child| jw_block(child, headings + [Text.normalize(block.title)], explicit_anchor(block.id), units, state) }
      when :preamble, :open
        block.blocks.each { |child| jw_block(child, headings, section_anchor, units, state) }
      when :paragraph
        text = visible_node(block)
        paragraph = paragraph_number(block.id, text)
        unit = build_unit(block, 'prose', text, headings, section_anchor)
        unit.paragraph_start = paragraph
        unit.paragraph_end = paragraph
        units << unit unless text.empty?
        state[:current] = text.empty? ? nil : unit
      when :ulist, :olist, :dlist, :admonition, :quote, :verse, :table, :image
        text = block.context == :image ? [block.title, block.attr('alt')].compact.join(' — ') : visible_node(block)
        if state[:current]
          append_to_unit(state[:current], text, block)
        elsif !Text.normalize(text).empty?
          units << build_unit(block, 'prose', text, headings, section_anchor)
          state[:current] = units.last
        end
      when :listing, :literal
        append_to_unit(state[:current], Text.normalize(block.source), block) if state[:current]
      else
        block.blocks.each { |child| jw_block(child, headings, section_anchor, units, state) if child.respond_to?(:context) } if block.respond_to?(:blocks)
      end
    end

    def skip_block?(block)
      roles = block.respond_to?(:roles) ? block.roles.to_set : Set.new
      return true unless (roles & SKIPPED_ROLES).empty?
      return true if family == 'notes' && technical_preservation_block?(block)

      if block.context == :paragraph
        text = visible_node(block)
        return true if text.match?(/\A(?:←\s*)?(?:Voltar|Back)\b/i)
      end
      false
    end

    def technical_preservation_block?(block)
      title = Text.normalize(block.respond_to?(:title) ? block.title : nil)
      roles = block.respond_to?(:roles) ? block.roles : []
      (block.context == :example && title.match?(/Dados preservados da extração/i)) ||
        roles.any? { |role| role.match?(/migration|preserv/i) }
    end

    def visible_node(block)
      value = if block.context == :paragraph && block.respond_to?(:content)
                block.content
              elsif block.respond_to?(:convert)
                block.convert
              elsif block.respond_to?(:content)
                block.content
              end
      Text.visible_html(value)
        .gsub(/xref:[^\[]+\[([^\]]*)\]/, '\\1')
        .gsub(/link:[^\[]+\[([^\]]*)\]/, '\\1')
        .then { |text| Text.normalize(text) }
    rescue StandardError
      Text.normalize(block.respond_to?(:source) ? block.source : '')
    end

    def table_units(block, headings, section_anchor)
      rows = []
      if block.respond_to?(:rows)
        block.rows.head.to_a.concat(block.rows.body.to_a).each do |row|
          text = row.map { |cell| Text.visible_html(cell.text) }.join(' | ')
          rows << build_unit(block, 'table', text, headings, section_anchor) unless Text.normalize(text).empty?
        end
      end
      rows.empty? ? [build_unit(block, 'table', visible_node(block), headings, section_anchor)] : rows
    end

    def add_unit(units, block, kind, text, headings, section_anchor)
      normalized = Text.normalize(text)
      units << build_unit(block, kind, normalized, headings, section_anchor) unless normalized.empty?
    end

    def build_unit(block, kind, text, headings, section_anchor)
      line = block.respond_to?(:lineno) ? block.lineno : nil
      page = source_pages.at(line)
      Unit.new(
        kind: kind,
        text: Text.normalize(text),
        heading_path: headings.map { |heading| Text.normalize(heading) }.reject(&:empty?),
        anchor: explicit_anchor(block.respond_to?(:id) ? block.id : nil),
        section_anchor: section_anchor,
        line: line,
        source_page_start: page,
        source_page_end: page
      )
    end

    def append_to_unit(unit, text, block)
      normalized = Text.normalize(text)
      return if normalized.empty?

      unit.text = Text.normalize([unit.text, normalized].join("\n\n"))
      page = source_pages.at(block.respond_to?(:lineno) ? block.lineno : nil)
      unit.source_page_start ||= page
      unit.source_page_end = page if page
    end

    def explicit_anchor(value)
      id = value.to_s.strip
      return nil if id.empty? || id.start_with?('_')

      id
    end

    def verse_number(anchor, text)
      return Regexp.last_match(1).to_i if anchor.to_s.match(/(?:\A|[-_])(\d+)\z/)
      return Regexp.last_match(1).to_i if text.match(/\A(\d+)\s+/)

      nil
    end

    def paragraph_number(anchor, text)
      return Regexp.last_match(1).to_i if anchor.to_s.match(/(?:\A|[-_])p(?:ar)?-?(\d+)\z/i)
      return Regexp.last_match(1).to_i if text.match(/\A(\d+)[.)]?\s+/)

      nil
    end
  end

  class ChunkBuilder
    attr_reader :family, :corpus, :source_key, :document, :metadata

    def initialize(family:, corpus:, source_key:, document:, metadata:)
      @family = family
      @corpus = corpus
      @source_key = source_key
      @document = document
      @metadata = metadata
    end

    def build(units)
      groups = case family
               when 'bible' then bounded_groups(expand_oversized(units), maximum_units: 12)
               when 'jw' then bounded_groups(expand_oversized(units), maximum_units: 8)
               else structural_groups(expand_oversized(units))
               end
      occurrences = Hash.new(0)
      chunks = groups.each_with_index.map do |group, index|
        ordinal = index + 1
        text = Text.normalize(group.map(&:text).join("\n\n"))
        raise Error, "empty chunk for #{source_key}" if text.empty?
        raise Error, "chunk exceeds 1,200 words for #{source_key}" if Text.word_count(text) > 1_200

        section_key = section_key(group, occurrences)
        source = source_for(group)
        chunk = {
          'id' => Identifiers.chunk(corpus.id, source_key, section_key, ordinal),
          'ordinal' => ordinal,
          'headingPath' => group.first.heading_path,
          'kind' => chunk_kind(group),
          'text' => text,
          'charCount' => Text.char_count(text),
          'wordCount' => Text.word_count(text),
          'contentHash' => Hashing.sha256_bytes(text.encode('UTF-8')),
          'source' => source
        }
        anchor = group.first.anchor || group.first.section_anchor
        chunk['anchor'] = anchor if anchor
        chunk
      end
      chunks.each_with_index do |chunk, index|
        chunk['previousId'] = chunks[index - 1]['id'] if index.positive?
        chunk['nextId'] = chunks[index + 1]['id'] if index < chunks.length - 1
      end
      chunks
    end

    private

    def expand_oversized(units)
      units.flat_map do |unit|
        next unit if Text.word_count(unit.text) <= 1_200

        parts = split_oversized_text(unit.text)
        parts.each_with_index.map do |text, index|
          copy = unit.dup
          copy.text = text
          copy.anchor = nil if index.positive?
          copy
        end
      end
    end

    def split_oversized_text(value)
      normalized = Text.normalize(value)
      semantic_units = normalized.split(/\n+/).map { |item| Text.normalize(item) }.reject(&:empty?)
      semantic_units = [normalized] if semantic_units.empty?
      atomic_units = semantic_units.flat_map do |item|
        next item if Text.word_count(item) <= 1_200

        sentences = Text.sentences(item)
        sentences = [item] if sentences.empty?
        sentences.flat_map do |sentence|
          next sentence if Text.word_count(sentence) <= 1_200

          sentence.split(/\p{Space}+/u).each_slice(1_200).map { |words| words.join(' ') }
        end
      end

      parts = []
      current = []
      current_words = 0
      atomic_units.each do |item|
        words = Text.word_count(item)
        if current_words + words > 1_200 && !current.empty?
          parts << Text.normalize(current.join("\n\n"))
          current = []
          current_words = 0
        end
        current << item
        current_words += words
      end
      parts << Text.normalize(current.join("\n\n")) unless current.empty?
      parts
    end

    def structural_groups(units)
      groups = []
      current = []
      current_words = 0
      units.each do |unit|
        words = Text.word_count(unit.text)
        compatible = current.empty? || (
          current.first.heading_path == unit.heading_path &&
          current.first.kind == unit.kind &&
          current_words + words <= 900
        )
        unless compatible
          groups << current
          current = []
          current_words = 0
        end
        current << unit
        current_words += words
      end
      groups << current unless current.empty?
      groups
    end

    def bounded_groups(units, maximum_units:)
      groups = []
      current = []
      current_words = 0
      units.each do |unit|
        words = Text.word_count(unit.text)
        raise Error, "atomic unit exceeds 1,200 words for #{source_key}" if words > 1_200
        if !current.empty? && (
          current.length >= maximum_units ||
          current_words + words > 900 ||
          current.first.heading_path != unit.heading_path
        )
          groups << current
          current = []
          current_words = 0
        end
        current << unit
        current_words += words
      end
      groups << current unless current.empty?
      groups
    end

    def section_key(group, occurrences)
      explicit = group.first.section_anchor || group.first.anchor
      return explicit if explicit

      headings = group.first.heading_path
      return 'document' if headings.length <= 1

      base = Text.slug(headings.join('-'))
      occurrences[base] += 1
      "#{base}-#{format('%04d', occurrences.fetch(base))}"
    end

    def chunk_kind(group)
      return 'verse-range' if family == 'bible'
      kinds = group.map(&:kind).uniq
      kinds.length == 1 ? kinds.first : 'prose'
    end

    def source_for(group)
      source = { 'sourceKey' => source_key }
      section = group.first.heading_path.drop(1).join(' > ')
      case family
      when 'book'
        source['section'] = section unless section.empty?
      when 'bible'
        source['book'] = metadata.fetch('book')
        source['chapter'] = metadata.fetch('chapter')
        starts = group.filter_map(&:verse_start)
        ends = group.filter_map(&:verse_end)
        source['verseStart'] = starts.min unless starts.empty?
        source['verseEnd'] = ends.max unless ends.empty?
      when 'jw'
        chapter_number = document.attr('chapter-number') || document.attr('source-chapter-number')
        source['chapter'] = chapter_number.to_i unless chapter_number.to_s.empty?
        source['section'] = section unless section.empty?
        starts = group.filter_map(&:paragraph_start)
        ends = group.filter_map(&:paragraph_end)
        source['paragraphStart'] = starts.min unless starts.empty?
        source['paragraphEnd'] = ends.max unless ends.empty?
        pages = page_range(group)
        source['sourcePages'] = pages if pages
        citation = document.attr('source-citation').to_s.strip
        source['citation'] = citation unless citation.empty?
      when 'notes'
        source['section'] = section unless section.empty?
        source['originId'] = metadata['originId'] if metadata['originId']
        source['originDate'] = metadata['originDate'] if metadata['originDate']
      end
      source
    end

    def page_range(group)
      starts = group.filter_map(&:source_page_start)
      ends = group.filter_map(&:source_page_end)
      return nil if starts.empty? && ends.empty?

      first = (starts + ends).min
      last = (starts + ends).max
      first == last ? first.to_s : "#{first}-#{last}"
    end
  end

  class Summaries
    attr_reader :family, :corpus

    def initialize(family:, corpus:)
      @family = family
      @corpus = corpus
    end

    def build(documents_with_chunks)
      return [] if family == 'bible'

      document_summaries = documents_with_chunks.filter_map do |entry|
        summarize_document(entry.fetch(:document), entry.fetch(:chunks))
      end
      corpus_chunks = documents_with_chunks.filter_map { |entry| entry.fetch(:chunks).first }.first(12)
      corpus_summary = summarize_corpus(corpus_chunks)
      [corpus_summary, *document_summaries].compact
    end

    private

    def summarize_document(document, chunks)
      evidence = chunks.first(8)
      return nil if evidence.empty?

      text = evidence.map { |chunk| chunk.fetch('text') }.join("\n\n")
      build_summary(
        id: Identifiers.summary('document', corpus.id, document.fetch('sourceKey')),
        scope: 'document',
        title: document.fetch('title'),
        text: text,
        chunks: evidence,
        document_id: document.fetch('id'),
        maximum_overview_words: 120
      )
    end

    def summarize_corpus(chunks)
      return nil if chunks.empty?

      text = chunks.map { |chunk| chunk.fetch('text') }.join("\n\n")
      build_summary(
        id: Identifiers.summary('corpus', corpus.id),
        scope: 'corpus',
        title: corpus.title,
        text: text,
        chunks: chunks,
        maximum_overview_words: 250
      )
    end

    def build_summary(id:, scope:, title:, text:, chunks:, maximum_overview_words:, document_id: nil)
      sentences = Text.sentences(text)
      return nil if sentences.empty?
      topics = Text.topics(text, corpus.language)
      return nil if topics.length < 3

      overview_source = sentences.first(3).join(' ')
      key_points = sentences.map { |sentence| Text.truncate_words(sentence, 80) }.uniq.first(3)
      return nil if key_points.empty?

      summary = {
        'id' => id,
        'scope' => scope,
        'corpusId' => corpus.id,
        'language' => corpus.language,
        'title' => title,
        'overview' => Text.truncate_words(overview_source, maximum_overview_words),
        'keyPoints' => key_points,
        'topics' => topics,
        'sourceDigest' => Hashing.evidence(chunks: chunks),
        'method' => 'extractive',
        'reviewStatus' => 'not-required',
        'sourceChunkIds' => chunks.map { |chunk| chunk.fetch('id') }
      }
      summary['documentId'] = document_id if document_id
      summary
    end
  end

  class Generator
    attr_reader :repository

    def initialize(repository = Repository.new)
      @repository = repository
    end

    def generate(replace: true)
      parent = Pathname.new(Dir.mktmpdir('.rag-build-', repository.root.to_s))
      output = parent.join('rag')
      FileUtils.mkdir_p(output)
      corpora = repository.discover_corpora
      manifest_corpora = corpora.map { |corpus| generate_corpus(corpus, output) }
      manifest = {
        'schemaVersion' => SCHEMA_VERSION,
        'repository' => repository.repository_name,
        'family' => repository.family,
        'generator' => { 'name' => GENERATOR_NAME, 'version' => GENERATOR_VERSION },
        'normalizationVersion' => NORMALIZATION_VERSION,
        'serialization' => SERIALIZATION,
        'sourceDigest' => repository.source_digest(corpora.flat_map { |corpus| corpus.source_paths.to_a }.uniq),
        'corpora' => manifest_corpora
      }
      write_json(output.join('manifest.json'), manifest)
      Validator.new(repository, output).validate!

      if replace
        replace_output(output)
        FileUtils.rm_rf(parent)
        repository.root.join('rag')
      else
        output
      end
    rescue StandardError
      FileUtils.rm_rf(parent) if parent
      raise
    end

    def check!
      generated = generate(replace: false)
      current = repository.root.join('rag')
      raise Error, 'rag/ does not exist; run generate first' unless current.directory?
      raise Error, 'rag/ is stale or nondeterministic' unless identical_trees?(current, generated)

      puts 'RAG artifacts are deterministic and current.'
    ensure
      FileUtils.rm_rf(generated.parent) if generated
    end

    private

    def generate_corpus(corpus, output)
      corpus_root = output.join('corpora', corpus.publication, corpus.edition)
      chunks_root = corpus_root.join('chunks')
      FileUtils.mkdir_p(chunks_root)
      documents = []
      documents_with_chunks = []
      corpus.pages.each do |source_path|
        entry = generate_document(corpus, source_path, output, chunks_root, documents.length + 1)
        next unless entry

        documents << entry.fetch(:document)
        documents_with_chunks << entry
      end

      summaries = Summaries.new(family: repository.family, corpus: corpus).build(documents_with_chunks)
      summaries_by_document = summaries.filter_map { |summary| [summary['documentId'], summary['id']] if summary['documentId'] }.to_h
      documents.each do |document|
        document['summaryId'] = summaries_by_document.fetch(document['id']) if summaries_by_document.key?(document['id'])
      end

      documents_path = corpus_root.join('documents.jsonl')
      summaries_path = corpus_root.join('summaries.jsonl')
      write_jsonl(documents_path, documents)
      write_jsonl(summaries_path, summaries)
      artifact_paths = [documents_path, summaries_path, *Dir.glob(chunks_root.join('**', '*.json').to_s).map { |path| Pathname.new(path) }]
      artifact_entries = artifact_paths.map { |path| [path.relative_path_from(corpus_root).to_s.tr('\\', '/'), File.binread(path)] }

      item = {
        'id' => corpus.id,
        'publication' => corpus.publication,
        'edition' => corpus.edition,
        'module' => corpus.module_name,
        'kind' => corpus.kind,
        'title' => corpus.title,
        'language' => corpus.language,
        'sourceOrder' => corpus.source_order,
        'documentsFile' => "corpora/#{corpus.publication}/#{corpus.edition}/documents.jsonl",
        'summariesFile' => "corpora/#{corpus.publication}/#{corpus.edition}/summaries.jsonl",
        'documents' => documents.length,
        'chunks' => documents_with_chunks.sum { |entry| entry.fetch(:chunks).length },
        'summaries' => summaries.length,
        'sourceDigest' => repository.source_digest(corpus.source_paths),
        'artifactDigest' => Hashing.file_set(artifact_entries)
      }
      item['label'] = corpus.label if corpus.label
      item
    end

    def generate_document(corpus, source_path, output, chunks_root, ordinal)
      absolute_path = repository.absolute(source_path)
      attributes = corpus.edition_data.fetch('attributes', {}).transform_keys(&:to_s).transform_values(&:to_s)
      attributes['edition-module'] = corpus.module_name
      attributes['attribute-missing'] = 'skip'
      attributes['attribute-undefined'] = 'drop-line'
      document = Asciidoctor.load_file(
        absolute_path.to_s,
        safe: :safe,
        base_dir: repository.root.to_s,
        parse: true,
        sourcemap: true,
        attributes: attributes
      )
      return nil if document.attr?('page-rag-exclude')

      title = Text.normalize(document.doctitle)
      raise Error, "document has no title: #{source_path}" if title.empty?

      match = source_path.match(%r{\Amodules/([^/]+)/pages/(.+)\z})
      raise Error, "document is outside modules/*/pages: #{source_path}" unless match
      module_name = match[1]
      relative = match[2]
      source_key = "#{module_name}/#{relative}"
      metadata = document_metadata(corpus, document, relative)
      kind = document_kind(corpus, document, relative)
      units = Extractor.new(
        family: repository.family,
        corpus: corpus,
        document: document,
        path: absolute_path.to_s
      ).extract
      semantic_text = Text.normalize(units.map(&:text).join("\n\n"))
      source_hash_data = {
        'title' => title,
        'language' => corpus.language,
        'kind' => kind
      }
      source_hash_data['metadata'] = metadata unless metadata.empty?
      source_hash_data['text'] = semantic_text
      source_hash = Hashing.canonical(source_hash_data)
      document_id = Identifiers.document(corpus.id, source_key)
      chunks = ChunkBuilder.new(
        family: repository.family,
        corpus: corpus,
        source_key: source_key,
        document: document,
        metadata: metadata
      ).build(units)
      chunk_relative = relative.sub(/\.adoc\z/i, '.json')
      chunk_file = "corpora/#{corpus.publication}/#{corpus.edition}/chunks/#{module_name}/#{chunk_relative}"
      chunk_payload = {
        'schemaVersion' => SCHEMA_VERSION,
        'documentId' => document_id,
        'sourceHash' => source_hash,
        'chunks' => chunks
      }
      write_json(output.join(chunk_file), chunk_payload)

      record = {
        'id' => document_id,
        'corpusId' => corpus.id,
        'publication' => corpus.publication,
        'edition' => corpus.edition,
        'module' => module_name,
        'relative' => relative,
        'sourcePath' => source_path,
        'sourceKey' => source_key,
        'title' => title,
        'language' => corpus.language,
        'kind' => kind,
        'ordinal' => ordinal,
        'sourceHash' => source_hash,
        'chunkFile' => chunk_file,
        'chunkCount' => chunks.length
      }
      record['metadata'] = metadata unless metadata.empty?
      { document: record, chunks: chunks }
    end

    def document_kind(corpus, document, relative)
      explicit = document.attr('page-rag-kind').to_s.strip
      unless explicit.empty?
        allowed = %w[frontmatter chapter appendix article bible-chapter note index analysis page]
        raise Error, "invalid page-rag-kind #{explicit}" unless allowed.include?(explicit)
        return explicit
      end

      case repository.family
      when 'bible' then File.basename(relative) == 'index.adoc' ? 'index' : 'bible-chapter'
      when 'jw' then corpus.kind == 'analysis' ? 'analysis' : 'chapter'
      when 'notes' then File.basename(relative) == 'index.adoc' ? 'index' : 'note'
      when 'book' then corpus.publication == 'articles' || relative.start_with?('articles/') ? 'article' : 'chapter'
      else 'page'
      end
    end

    def document_metadata(corpus, document, relative)
      publication = corpus.publication_data
      edition = corpus.edition_data
      metadata = {}
      metadata['author'] = publication['author'].to_s unless publication['author'].to_s.empty?
      metadata['isbn'] = publication['isbn'].to_s unless publication['isbn'].to_s.empty?
      metadata['slug'] = edition['slug'].to_s unless edition['slug'].to_s.empty?
      metadata['label'] = edition['label'].to_s unless edition['label'].to_s.empty?

      case repository.family
      when 'bible'
        unless File.basename(relative) == 'index.adoc'
          title = Text.normalize(document.doctitle)
          match = title.match(/\A(.+),\s*(\d+)\z/)
          raise Error, "Bible chapter title must end in ', N': #{title}" unless match
          metadata['book'] = match[1]
          metadata['chapter'] = match[2].to_i
        end
      when 'jw'
        copy_metadata(metadata, edition, 'mnemonic', 'mnemonic')
        copy_metadata(metadata, edition, 'languageCode', 'language_code')
        copy_metadata(metadata, edition, 'editionDate', 'edition_date')
        metadata['copyrightYears'] = edition['copyright_years'] if edition['copyright_years']&.any?
        copy_metadata(metadata, edition, 'territory', 'territory')
        copy_metadata(metadata, edition, 'variation', 'variation')
        source_citation = document.attr('source-citation').to_s.strip
        wol_source_url = document.attr('wol-source-url').to_s.strip
        metadata['sourceCitation'] = source_citation unless source_citation.empty?
        metadata['wolSourceUrl'] = wol_source_url unless wol_source_url.empty?
        if (match = source_citation.match(/págs?\.\s*([0-9]+(?:\s*[-–]\s*[0-9]+)?)/i))
          metadata['sourcePages'] = match[1].gsub(/\s+/, '').tr('–', '-')
        end
      when 'notes'
        note_attributes = {
          'originId' => 'page-origin-id',
          'originDate' => 'page-origin-date',
          'sourceUrl' => 'page-source-url',
          'sourceType' => 'page-source-type',
          'reviewStatus' => 'page-review-status',
          'bibleReference' => 'page-bible-reference'
        }
        note_attributes.each do |target, attribute|
          value = document.attr(attribute).to_s.strip
          metadata[target] = target == 'originId' && value.match?(/\A\d+\z/) ? value.to_i : value unless value.empty?
        end
        %w[categories tags].each do |target|
          value = document.attr("page-#{target}").to_s
          values = value.split(',').map { |item| Text.normalize(item) }.reject(&:empty?)
          metadata[target] = values unless values.empty?
        end
      end
      metadata
    end

    def copy_metadata(target, source, target_key, source_key)
      value = source[source_key]
      target[target_key] = value unless value.nil? || value.to_s.empty?
    end

    def write_json(path, value)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, "#{Canonical.dump(value)}\n".encode('UTF-8'))
    end

    def write_jsonl(path, values)
      FileUtils.mkdir_p(path.dirname)
      content = values.map { |value| Canonical.dump(value) }.join("\n")
      content = "#{content}\n"
      File.binwrite(path, content.encode('UTF-8'))
    end

    def replace_output(generated)
      target = repository.root.join('rag')
      backup = repository.root.join(".rag-backup-#{Process.pid}")
      raise Error, "unsafe RAG output target: #{target}" unless target.parent == repository.root && target.basename.to_s == 'rag'
      raise Error, "stale RAG backup exists: #{backup}" if backup.exist?

      return if target.directory? && identical_trees?(target, generated)

      FileUtils.mv(target, backup) if target.exist?
      begin
        FileUtils.mv(generated, target)
        FileUtils.rm_rf(backup) if backup.exist?
      rescue StandardError
        FileUtils.rm_rf(target) if target.exist?
        FileUtils.mv(backup, target) if backup.exist?
        raise
      end
    end

    def identical_trees?(left, right)
      left_files = Dir.glob(left.join('**', '*').to_s).select { |path| File.file?(path) }.map { |path| Pathname.new(path).relative_path_from(left).to_s.tr('\\', '/') }.sort_by(&:b)
      right_files = Dir.glob(right.join('**', '*').to_s).select { |path| File.file?(path) }.map { |path| Pathname.new(path).relative_path_from(right).to_s.tr('\\', '/') }.sort_by(&:b)
      left_files == right_files && left_files.all? { |relative| File.binread(left.join(relative)) == File.binread(right.join(relative)) }
    end
  end

  class Validator
    MANIFEST_FIELDS = %w[schemaVersion repository family generator normalizationVersion serialization sourceDigest corpora].to_set.freeze
    CORPUS_FIELDS = %w[id publication edition module kind title label language sourceOrder documentsFile summariesFile documents chunks summaries sourceDigest artifactDigest].to_set.freeze
    DOCUMENT_FIELDS = %w[id corpusId publication edition module relative sourcePath sourceKey title language kind ordinal sourceHash chunkFile chunkCount summaryId metadata].to_set.freeze
    CHUNK_FILE_FIELDS = %w[schemaVersion documentId sourceHash chunks].to_set.freeze
    CHUNK_FIELDS = %w[id ordinal headingPath kind text charCount wordCount contentHash source anchor previousId nextId].to_set.freeze
    SUMMARY_FIELDS = %w[id scope corpusId language title overview keyPoints topics sourceDigest method reviewStatus documentId sectionKey sourceChunkIds sourceSummaryIds model promptVersion generatedFrom].to_set.freeze
    MANIFEST_REQUIRED = MANIFEST_FIELDS.freeze
    CORPUS_REQUIRED = (CORPUS_FIELDS - %w[label]).freeze
    DOCUMENT_REQUIRED = (DOCUMENT_FIELDS - %w[summaryId metadata]).freeze
    CHUNK_FILE_REQUIRED = CHUNK_FILE_FIELDS.freeze
    CHUNK_REQUIRED = (CHUNK_FIELDS - %w[anchor previousId nextId]).freeze
    SUMMARY_REQUIRED = (SUMMARY_FIELDS - %w[documentId sectionKey sourceChunkIds sourceSummaryIds model promptVersion generatedFrom]).freeze
    GENERATOR_FIELDS = %w[name version].to_set.freeze
    COMMON_METADATA_FIELDS = %w[author isbn slug label].to_set.freeze
    FAMILY_METADATA_FIELDS = {
      'book' => Set.new,
      'bible' => %w[book chapter].to_set,
      'jw' => %w[mnemonic languageCode editionDate copyrightYears territory variation sourceCitation wolSourceUrl sourcePages].to_set,
      'notes' => %w[originId originDate sourceUrl sourceType reviewStatus categories tags bibleReference].to_set
    }.freeze
    FAMILY_SOURCE_FIELDS = {
      'book' => %w[sourceKey section].to_set,
      'bible' => %w[sourceKey book chapter verseStart verseEnd].to_set,
      'jw' => %w[sourceKey chapter section paragraphStart paragraphEnd sourcePages citation].to_set,
      'notes' => %w[sourceKey section originId originDate].to_set
    }.freeze
    DOCUMENT_KINDS = %w[frontmatter chapter appendix article bible-chapter note index analysis page].to_set.freeze
    CHUNK_KINDS = %w[prose list table quote admonition verse-range code image-description].to_set.freeze
    SUMMARY_SCOPES = %w[corpus document section].to_set.freeze
    SUMMARY_METHODS = %w[extractive ai human].to_set.freeze
    REVIEW_STATUSES = %w[not-required pending reviewed].to_set.freeze
    SHA256_PATTERN = /\Asha256:[0-9a-f]{64}\z/
    CREDENTIAL_PATTERN = /(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|sk-(?:proj-)?[A-Za-z0-9_-]{16,}|Authorization\s*:\s*Bearer\s+\S+|https?:\/\/[^\s\/@]+:[^\s\/@]+@)/i

    attr_reader :repository, :rag_root

    def initialize(repository = Repository.new, rag_root = nil)
      @repository = repository
      @rag_root = Pathname.new(rag_root || repository.root.join('rag')).expand_path
    end

    def validate!
      raise Error, "RAG directory does not exist: #{rag_root}" unless rag_root.directory?
      scan_credentials!
      manifest = read_json(rag_root.join('manifest.json'))
      exact_fields!(manifest, MANIFEST_FIELDS, MANIFEST_REQUIRED, 'manifest')
      validate_manifest_identity!(manifest)
      expected_corpora = repository.discover_corpora
      expected_ids = expected_corpora.map(&:id)
      actual_ids = manifest.fetch('corpora').map { |corpus| corpus.fetch('id') }
      raise Error, 'manifest corpus order does not match publication.yml' unless actual_ids == expected_ids
      expected_by_id = expected_corpora.to_h { |corpus| [corpus.id, corpus] }

      all_document_ids = Set.new
      all_chunk_ids = Set.new
      all_summary_ids = Set.new
      manifest.fetch('corpora').each do |item|
        validate_corpus!(item, expected_by_id.fetch(item.fetch('id')), all_document_ids, all_chunk_ids, all_summary_ids)
      end
      expected_global = repository.source_digest(expected_corpora.flat_map { |corpus| corpus.source_paths.to_a }.uniq)
      raise Error, 'global sourceDigest mismatch' unless manifest.fetch('sourceDigest') == expected_global
      puts "Validated #{manifest.fetch('corpora').length} corpora, #{all_document_ids.length} documents, #{all_chunk_ids.length} chunks, and #{all_summary_ids.length} summaries."
      true
    end

    private

    def validate_manifest_identity!(manifest)
      raise Error, 'unsupported schemaVersion' unless manifest['schemaVersion'] == SCHEMA_VERSION
      raise Error, 'repository mismatch' unless manifest['repository'] == repository.repository_name
      raise Error, 'family mismatch' unless manifest['family'] == repository.family
      exact_fields!(manifest.fetch('generator'), GENERATOR_FIELDS, GENERATOR_FIELDS, 'manifest generator')
      raise Error, 'generator mismatch' unless manifest['generator'] == { 'name' => GENERATOR_NAME, 'version' => GENERATOR_VERSION }
      raise Error, 'normalizationVersion mismatch' unless manifest['normalizationVersion'] == NORMALIZATION_VERSION
      raise Error, 'serialization mismatch' unless manifest['serialization'] == SERIALIZATION
      validate_digest!(manifest['sourceDigest'], 'manifest sourceDigest')
      raise Error, 'manifest corpora must be an array' unless manifest['corpora'].is_a?(Array)
    end

    def validate_corpus!(item, expected, all_document_ids, all_chunk_ids, all_summary_ids)
      exact_fields!(item, CORPUS_FIELDS, CORPUS_REQUIRED, "corpus #{item['id']}")
      %w[publication edition module kind title language sourceOrder].each do |field|
        expected_value = {
          'publication' => expected.publication,
          'edition' => expected.edition,
          'module' => expected.module_name,
          'kind' => expected.kind,
          'title' => expected.title,
          'language' => expected.language,
          'sourceOrder' => expected.source_order
        }.fetch(field)
        raise Error, "#{item['id']} #{field} mismatch" unless item[field] == expected_value
      end
      raise Error, "#{item['id']} label mismatch" unless item['label'] == expected.label
      raise Error, "#{item['id']} sourceDigest mismatch" unless item['sourceDigest'] == repository.source_digest(expected.source_paths)
      validate_digest!(item['sourceDigest'], "#{item['id']} sourceDigest")
      validate_digest!(item['artifactDigest'], "#{item['id']} artifactDigest")
      %w[documents chunks summaries].each do |field|
        raise Error, "#{item['id']} #{field} must be a nonnegative integer" unless item[field].is_a?(Integer) && item[field] >= 0
      end

      documents_path = rag_root.join(item.fetch('documentsFile'))
      summaries_path = rag_root.join(item.fetch('summariesFile'))
      documents = read_jsonl(documents_path)
      summaries = read_jsonl(summaries_path)
      chunks = []
      corpus_document_ids = Set.new
      corpus_chunk_ids = Set.new
      chunk_by_id = {}
      expected_sources = expected.pages.reject { |source_path| rag_excluded?(repository.absolute(source_path)) }
      actual_sources = documents.map { |document| document['sourcePath'] }
      raise Error, "#{item['id']} document order does not match its contents" unless actual_sources == expected_sources
      documents.each_with_index do |document, index|
        exact_fields!(document, DOCUMENT_FIELDS, DOCUMENT_REQUIRED, "document #{document['id']}")
        raise Error, 'document ordinal mismatch' unless document['ordinal'] == index + 1
        validate_document!(document, expected)
        unique!(all_document_ids, document.fetch('id'))
        unique!(corpus_document_ids, document.fetch('id'))
        chunk_payload = read_json(rag_root.join(document.fetch('chunkFile')))
        exact_fields!(chunk_payload, CHUNK_FILE_FIELDS, CHUNK_FILE_REQUIRED, "chunk file #{document['chunkFile']}")
        raise Error, 'chunk schemaVersion mismatch' unless chunk_payload['schemaVersion'] == SCHEMA_VERSION
        raise Error, 'chunk documentId mismatch' unless chunk_payload['documentId'] == document['id']
        raise Error, 'chunk sourceHash mismatch' unless chunk_payload['sourceHash'] == document['sourceHash']
        raise Error, 'chunkCount mismatch' unless chunk_payload.fetch('chunks').length == document['chunkCount']
        validate_chunks!(chunk_payload.fetch('chunks'), document, all_chunk_ids, corpus_chunk_ids, chunk_by_id)
        chunks.concat(chunk_payload.fetch('chunks'))
      end
      corpus_summary_ids = validate_summaries!(summaries, item.fetch('id'), all_summary_ids, corpus_chunk_ids, chunk_by_id, corpus_document_ids)
      documents.each do |document|
        next unless document['summaryId']

        raise Error, "unknown document summaryId #{document['summaryId']}" unless corpus_summary_ids.include?(document['summaryId'])
      end
      raise Error, "#{item['id']} document count mismatch" unless item['documents'] == documents.length
      raise Error, "#{item['id']} chunk count mismatch" unless item['chunks'] == chunks.length
      raise Error, "#{item['id']} summary count mismatch" unless item['summaries'] == summaries.length

      corpus_root = documents_path.dirname
      artifact_paths = [documents_path, summaries_path, *documents.map { |document| rag_root.join(document.fetch('chunkFile')) }].uniq
      entries = artifact_paths.map { |path| [path.relative_path_from(corpus_root).to_s.tr('\\', '/'), File.binread(path)] }
      raise Error, "#{item['id']} artifactDigest mismatch" unless item['artifactDigest'] == Hashing.file_set(entries)
    end

    def validate_document!(document, expected)
      %w[id corpusId publication edition module relative sourcePath sourceKey title language kind sourceHash chunkFile].each do |field|
        raise Error, "document #{document['id']} #{field} must be a nonempty string" unless document[field].is_a?(String) && !document[field].empty?
      end
      raise Error, 'document corpusId mismatch' unless document['corpusId'] == expected.id
      raise Error, 'document publication mismatch' unless document['publication'] == expected.publication
      raise Error, 'document edition mismatch' unless document['edition'] == expected.edition
      allowed_module = document['module'] == expected.module_name || document['module'] == 'ROOT'
      raise Error, 'document module mismatch' unless allowed_module
      raise Error, 'document sourcePath mismatch' unless document['sourcePath'] == "modules/#{document['module']}/pages/#{document['relative']}"
      raise Error, 'document sourceKey mismatch' unless document['sourceKey'] == "#{document['module']}/#{document['relative']}"
      raise Error, 'document id mismatch' unless document['id'] == Identifiers.document(expected.id, document['sourceKey'])
      raise Error, 'document language mismatch' unless document['language'] == expected.language
      raise Error, "unsupported document kind #{document['kind']}" unless DOCUMENT_KINDS.include?(document['kind'])
      raise Error, 'document chunkCount must be a nonnegative integer' unless document['chunkCount'].is_a?(Integer) && document['chunkCount'] >= 0
      validate_digest!(document['sourceHash'], "document #{document['id']} sourceHash")
      expected_chunk_file = "corpora/#{expected.publication}/#{expected.edition}/chunks/#{document['module']}/#{document['relative'].sub(/\.adoc\z/i, '.json')}"
      raise Error, 'document chunkFile mismatch' unless document['chunkFile'] == expected_chunk_file
      if document['metadata']
        allowed = COMMON_METADATA_FIELDS | FAMILY_METADATA_FIELDS.fetch(repository.family)
        exact_fields!(document['metadata'], allowed, Set.new, "document #{document['id']} metadata")
      end
    end

    def validate_chunks!(chunks, document, all_chunk_ids, corpus_chunk_ids, chunk_by_id)
      raise Error, 'chunks must be an array' unless chunks.is_a?(Array)
      chunks.each_with_index do |chunk, index|
        exact_fields!(chunk, CHUNK_FIELDS, CHUNK_REQUIRED, "chunk #{chunk['id']}")
        raise Error, 'chunk ordinal mismatch' unless chunk['ordinal'] == index + 1
        raise Error, 'chunk headingPath must contain a title' unless chunk['headingPath'].is_a?(Array) && !chunk['headingPath'].empty? && chunk['headingPath'].all? { |value| value.is_a?(String) && !value.empty? }
        raise Error, "unsupported chunk kind #{chunk['kind']}" unless CHUNK_KINDS.include?(chunk['kind'])
        raise Error, 'chunk text must be nonempty' unless chunk['text'].is_a?(String) && !chunk['text'].empty?
        raise Error, 'chunk charCount mismatch' unless chunk['charCount'] == Text.char_count(chunk['text'])
        raise Error, 'chunk wordCount mismatch' unless chunk['wordCount'] == Text.word_count(chunk['text'])
        raise Error, 'chunk contentHash mismatch' unless chunk['contentHash'] == Hashing.sha256_bytes(chunk['text'].encode('UTF-8'))
        validate_digest!(chunk['contentHash'], "chunk #{chunk['id']} contentHash")
        raise Error, 'chunk exceeds 1,200 words' if chunk['wordCount'] > 1_200
        exact_fields!(chunk.fetch('source'), FAMILY_SOURCE_FIELDS.fetch(repository.family), %w[sourceKey].to_set, "chunk #{chunk['id']} source")
        raise Error, 'chunk sourceKey mismatch' unless chunk.fetch('source').fetch('sourceKey') == document['sourceKey']
        unique!(all_chunk_ids, chunk.fetch('id'))
        unique!(corpus_chunk_ids, chunk.fetch('id'))
        chunk_by_id[chunk.fetch('id')] = chunk
        previous = index.positive? ? chunks[index - 1]['id'] : nil
        following = index < chunks.length - 1 ? chunks[index + 1]['id'] : nil
        raise Error, 'chunk previousId mismatch' unless chunk['previousId'] == previous
        raise Error, 'chunk nextId mismatch' unless chunk['nextId'] == following
      end
    end

    def validate_summaries!(summaries, corpus_id, all_summary_ids, corpus_chunk_ids, chunk_by_id, corpus_document_ids)
      raise Error, 'summaries must be an array' unless summaries.is_a?(Array)
      scopes = summaries.map { |summary| summary['scope'] }
      raise Error, 'corpus summary must be first' if scopes.include?('corpus') && scopes.first != 'corpus'
      corpus_summary_ids = Set.new
      summary_by_id = {}
      summaries.each do |summary|
        exact_fields!(summary, SUMMARY_FIELDS, SUMMARY_REQUIRED, "summary #{summary['id']}")
        raise Error, 'summary corpusId mismatch' unless summary['corpusId'] == corpus_id
        raise Error, "unsupported summary scope #{summary['scope']}" unless SUMMARY_SCOPES.include?(summary['scope'])
        raise Error, "unsupported summary method #{summary['method']}" unless SUMMARY_METHODS.include?(summary['method'])
        raise Error, "unsupported summary reviewStatus #{summary['reviewStatus']}" unless REVIEW_STATUSES.include?(summary['reviewStatus'])
        raise Error, 'summary title must be nonempty' unless summary['title'].is_a?(String) && !summary['title'].empty?
        raise Error, 'summary overview must be nonempty' unless summary['overview'].is_a?(String) && !summary['overview'].empty?
        raise Error, 'summary overview too long' if Text.word_count(summary['overview']) > (summary['scope'] == 'corpus' ? 250 : 120)
        raise Error, 'summary keyPoints invalid' unless summary['keyPoints'].is_a?(Array) && summary['keyPoints'].length.between?(1, 8)
        raise Error, 'summary topics invalid' unless summary['topics'].is_a?(Array) && summary['topics'].length.between?(3, 12)
        raise Error, 'summary documentId is required for document or section scope' if %w[document section].include?(summary['scope']) && !summary['documentId']
        raise Error, 'summary documentId is not allowed for corpus scope' if summary['scope'] == 'corpus' && summary['documentId']
        raise Error, 'summary sectionKey is required for section scope' if summary['scope'] == 'section' && !summary['sectionKey']
        raise Error, 'summary sectionKey is only allowed for section scope' if summary['scope'] != 'section' && summary['sectionKey']
        raise Error, "unknown summary documentId #{summary['documentId']}" if summary['documentId'] && !corpus_document_ids.include?(summary['documentId'])
        chunk_ids = summary.fetch('sourceChunkIds', [])
        summary_ids = summary.fetch('sourceSummaryIds', [])
        raise Error, 'summary sourceChunkIds must be a nonempty array when present' if summary.key?('sourceChunkIds') && (!chunk_ids.is_a?(Array) || chunk_ids.empty?)
        raise Error, 'summary sourceSummaryIds must be a nonempty array when present' if summary.key?('sourceSummaryIds') && (!summary_ids.is_a?(Array) || summary_ids.empty?)
        evidence = chunk_ids + summary_ids
        raise Error, 'summary has no evidence' if evidence.empty?
        chunk_ids.each { |id| raise Error, "unknown summary chunk evidence #{id}" unless corpus_chunk_ids.include?(id) }
        summary_ids.each { |id| raise Error, "summary evidence is not earlier in this corpus: #{id}" unless corpus_summary_ids.include?(id) }
        evidence_chunks = chunk_ids.map { |id| chunk_by_id.fetch(id) }
        evidence_summaries = summary_ids.map { |id| summary_by_id.fetch(id) }
        raise Error, 'summary sourceDigest mismatch' unless summary['sourceDigest'] == Hashing.evidence(chunks: evidence_chunks, summaries: evidence_summaries)
        validate_digest!(summary['sourceDigest'], "summary #{summary['id']} sourceDigest")
        unique!(all_summary_ids, summary.fetch('id'))
        unique!(corpus_summary_ids, summary.fetch('id'))
        summary_by_id[summary.fetch('id')] = summary
      end
      corpus_summary_ids
    end

    def exact_fields!(object, allowed, required, label)
      raise Error, "#{label} is not an object" unless object.is_a?(Hash)
      extras = object.keys.to_set - allowed
      raise Error, "#{label} has unsupported fields: #{extras.to_a.sort.join(', ')}" unless extras.empty?
      missing = required - object.keys.to_set
      raise Error, "#{label} is missing required fields: #{missing.to_a.sort.join(', ')}" unless missing.empty?
    end

    def validate_digest!(value, label)
      raise Error, "#{label} is not a SHA-256 digest" unless value.is_a?(String) && value.match?(SHA256_PATTERN)
    end

    def rag_excluded?(path)
      return false unless path.file?

      text = File.binread(path).sub(/\A\xEF\xBB\xBF/n, '').force_encoding('UTF-8')
      raise Error, "source is not valid UTF-8: #{path}" unless text.valid_encoding?
      text.match?(/^:page-rag-exclude:\s*$/)
    end

    def unique!(set, id)
      raise Error, "duplicate ID: #{id}" if set.include?(id)
      set << id
    end

    def read_json(path)
      bytes = File.binread(path).force_encoding('UTF-8')
      raise Error, "JSON is not valid UTF-8: #{path}" unless bytes.valid_encoding?
      value = JSON.parse(bytes)
      raise Error, "noncanonical JSON: #{path}" unless bytes == "#{Canonical.dump(value)}\n".encode('UTF-8')
      value
    rescue Errno::ENOENT
      raise Error, "missing JSON file: #{path}"
    rescue JSON::ParserError => error
      raise Error, "invalid JSON in #{path}: #{error.message}"
    end

    def read_jsonl(path)
      bytes = File.binread(path)
      raise Error, "JSONL must end in LF: #{path}" unless bytes.end_with?("\n")
      text = bytes.force_encoding('UTF-8')
      raise Error, "JSONL is not valid UTF-8: #{path}" unless text.valid_encoding?
      lines = text.lines(chomp: true)
      lines.reject(&:empty?).map.with_index do |line, index|
        value = JSON.parse(line)
        raise Error, "noncanonical JSONL at #{path}:#{index + 1}" unless line == Canonical.dump(value)
        value
      end
    rescue Errno::ENOENT
      raise Error, "missing JSONL file: #{path}"
    rescue JSON::ParserError => error
      raise Error, "invalid JSONL in #{path}: #{error.message}"
    end

    def scan_credentials!
      Dir.glob(rag_root.join('**', '*').to_s).select { |path| File.file?(path) }.each do |path|
        text = File.binread(path).force_encoding('UTF-8')
        raise Error, "RAG artifact is not valid UTF-8: #{path}" unless text.valid_encoding?
        raise Error, "credential-like value detected in #{path}" if text.match?(CREDENTIAL_PATTERN)
      end
    end
  end

  module CLI
    module_function

    def run(arguments)
      command = arguments.shift || 'generate'
      raise Error, "unexpected arguments: #{arguments.join(' ')}" unless arguments.empty?

      repository = Repository.new
      case command
      when 'generate'
        output = Generator.new(repository).generate
        puts "Generated #{output}."
      when 'validate'
        Validator.new(repository).validate!
      when 'check'
        Generator.new(repository).check!
      else
        raise Error, "unknown command #{command.inspect}; use generate, validate, or check"
      end
    rescue Error => error
      warn "docs-rag: #{error.message}"
      exit 1
    end
  end
end

DocsRag::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
