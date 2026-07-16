require 'fileutils'
require 'yaml'

SOURCE = 'asciidoctor/support/publication.adoc'
METADATA = 'asciidoctor/publication.yml'
OUTPUT_ROOT = 'build/publications'

FORMATS = {
  html: ['asciidoctor', 'html'],
  pdf: ['asciidoctor-pdf', 'pdf'],
  epub: ['asciidoctor-epub3', 'epub']
}.freeze

COMMON_ATTRIBUTES = File.join('asciidoctor', 'support', 'attributes', 'common.adoc')
SHARED_IMAGES = File.join('modules', 'ROOT', 'assets', 'images')
EPUB_IMAGES_STAGE = File.join('asciidoctor', 'support', 'epub-images')

def attributes_from(path)
  File.readlines(path, chomp: true).filter_map do |line|
    match = line.match(/^:([^:]+):\s*(.*)$/)
    [match[1], match[2]] if match
  end.to_h
end

def language_attributes(language)
  language_slug = language.downcase.tr('_', '-')
  attributes_from(File.join('asciidoctor', 'support', 'attributes', "#{language_slug}.adoc"))
end

def common_attributes
  attributes_from(COMMON_ATTRIBUTES)
end

desc 'Generate HTML, PDF, and EPUB for all configured editions'
task default: :build

task :build do
  metadata = YAML.safe_load_file(METADATA)
  FileUtils.rm_rf OUTPUT_ROOT
  FileUtils.rm_rf EPUB_IMAGES_STAGE

  metadata.fetch('editions').each do |module_name, edition|
    destination = File.join(OUTPUT_ROOT, module_name)
    FileUtils.mkdir_p destination
    attributes = common_attributes
      .merge(language_attributes(edition.fetch('lang')))
      .merge(edition.fetch('attributes', {}).compact)

    FORMATS.each_value do |command, extension|
      epub_images_staged = false
      begin
        format_attributes = attributes
        if extension == 'epub'
          FileUtils.mkdir EPUB_IMAGES_STAGE
          epub_images_staged = true
          FileUtils.cp_r Dir.children(SHARED_IMAGES).map { |name| File.join(SHARED_IMAGES, name) }, EPUB_IMAGES_STAGE
          format_attributes = attributes.merge('imagesdir' => File.basename(EPUB_IMAGES_STAGE))
        end

        arguments = [
          'bundle', 'exec', command,
          '-D', destination,
          '-o', "#{edition.fetch('slug')}.#{extension}",
          '-a', "publication-title=#{edition.fetch('title')}",
          '-a', "publication-lang=#{edition.fetch('lang')}",
          '-a', "publication-author=#{metadata.fetch('author')}",
          '-a', "publication-isbn=#{metadata.fetch('isbn')}",
          '-a', "language-profile=#{edition.fetch('lang').downcase.tr('_', '-')}",
          '-a', "edition-module=#{module_name}"
        ]
        format_attributes.each { |name, value| arguments.concat ['-a', "#{name}=#{value}"] }
        arguments.concat ['-a', 'data-uri'] if extension == 'html'
        arguments << SOURCE
        sh(*arguments)
      ensure
        FileUtils.rm_rf EPUB_IMAGES_STAGE if epub_images_staged
      end
    end
  end
end
