# frozen_string_literal: true

require_relative '../scripts/docs-rag'

module DocsRagTest
  module_function

  @assertions = 0

  def pass
    @assertions += 1
  end

  def assert_equal(expected, actual, label)
    if expected == actual
      pass
      return
    end

    raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
  end

  def assert_match(pattern, actual, label)
    if pattern.match?(actual)
      pass
      return
    end

    raise "#{label}: #{actual.inspect} does not match #{pattern.inspect}"
  end

  def assert_not_equal(left, right, label)
    if left != right
      pass
      return
    end

    raise "#{label}: values unexpectedly match"
  end

  def assert_raises(error_class, message, label)
    yield
    raise "#{label}: expected #{error_class}"
  rescue error_class => error
    assert_match(message, error.message, label)
  end

  def run
    value = { 'z' => ['ação'], 'a' => { 'b' => true, 'a' => 1 } }
    canonical = DocsRag::Canonical.dump(value)
    assert_equal '{"a":{"a":1,"b":true},"z":["ação"]}', canonical, 'canonical key order'
    assert_equal canonical, DocsRag::Canonical.dump(JSON.parse(canonical)), 'canonical round trip'

    assert_equal 'pt-br/cap%C3%ADtulo%201.adoc', DocsRag::Identifiers.encode_path('pt-br/capítulo 1.adoc'), 'RFC 3986 path'
    assert_equal(
      'document:default/pt-br/pt-br/cap%C3%ADtulo%201.adoc',
      DocsRag::Identifiers.document('default/pt-br', 'pt-br/capítulo 1.adoc'),
      'document ID'
    )
    assert_equal(
      'summary:section/default/pt-br/pt-br/cap%C3%ADtulo%201.adoc#se%C3%A7%C3%A3o%201',
      DocsRag::Identifiers.summary('section', 'default/pt-br', 'pt-br/capítulo 1.adoc', 'seção 1'),
      'summary ID'
    )

    decomposed = "Cafe\u0301  \r\n\r\n\r\ntexto \r\n"
    assert_equal "Café\n\ntexto", DocsRag::Text.normalize(decomposed), 'text normalization'
    assert_equal 2, DocsRag::Text.word_count("Café\ntexto"), 'word count'
    assert_equal 10, DocsRag::Text.char_count("Café\ntexto"), 'character count'

    text = 'Rotina matinal melhora a rotina. A prática matinal organiza o dia e a prática.'
    assert_equal %w[rotina matinal prática melhora organiza dia], DocsRag::Text.topics(text, 'pt-BR'), 'topics'

    digest = DocsRag::Hashing.sha256_bytes('conteúdo'.encode('UTF-8'))
    assert_match(/\Asha256:[0-9a-f]{64}\z/, digest, 'SHA-256 format')
    assert_equal(
      DocsRag::Hashing.canonical({ 'b' => 2, 'a' => 1 }),
      DocsRag::Hashing.canonical({ 'a' => 1, 'b' => 2 }),
      'canonical hash stability'
    )

    first_chunk = {
      'id' => 'chunk:first',
      'contentHash' => digest,
      'headingPath' => ['Primeiro'],
      'source' => { 'sourceKey' => 'pt-br/primeiro.adoc' }
    }
    second_chunk = first_chunk.merge('id' => 'chunk:second')
    assert_not_equal(
      DocsRag::Hashing.evidence(chunks: [first_chunk, second_chunk]),
      DocsRag::Hashing.evidence(chunks: [second_chunk, first_chunk]),
      'evidence order changes its digest'
    )

    validator = DocsRag::Validator.allocate
    assert_raises(DocsRag::Error, /missing required fields: id/, 'required field validation') do
      validator.send(:exact_fields!, {}, %w[id optional].to_set, %w[id].to_set, 'fixture')
    end
    assert_raises(DocsRag::Error, /unsupported fields: extra/, 'unsupported field validation') do
      validator.send(:exact_fields!, { 'id' => 'ok', 'extra' => true }, %w[id].to_set, %w[id].to_set, 'fixture')
    end

    oversized = (1..2_501).map { |index| "palavra#{index}" }.join(' ')
    parts = DocsRag::ChunkBuilder.allocate.send(:split_oversized_text, oversized)
    assert_equal [1_200, 1_200, 101], parts.map { |part| DocsRag::Text.word_count(part) }, 'oversized fallback split'

    Dir.mktmpdir('docs-rag-test') do |root|
      root_path = Pathname.new(root)
      contents = root_path.join('asciidoctor/contents/sample.adoc')
      master = root_path.join('modules/sample/pages/_master.adoc')
      child = root_path.join('modules/sample/pages/child.adoc')
      FileUtils.mkdir_p(contents.dirname)
      FileUtils.mkdir_p(master.dirname)
      File.write(contents, "include::../../modules/{edition-module}/pages/_master.adoc[]\n")
      File.write(master, "include::child.adoc[]\n")
      File.write(child, "= Child\n\nContent.\n")
      repository = DocsRag::Repository.allocate
      repository.instance_variable_set(:@root, root_path)
      sources = Set.new
      pages = []
      repository.send(
        :scan_includes,
        contents,
        { 'edition-module' => 'sample' },
        sources,
        pages,
        discover_pages: true,
        stack: []
      )
      assert_equal ['modules/sample/pages/child.adoc'], pages, 'master expands to page documents'
      assert_equal true, sources.include?('modules/sample/pages/_master.adoc'), 'master remains a digest source'
    end

    puts "docs-rag unit tests passed (#{@assertions} assertions)."
  end
end

DocsRagTest.run
