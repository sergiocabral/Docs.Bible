# Instruções para agentes de inteligência artificial

## Objetivo

Este é um modelo de publicação em AsciiDoc com três usos:

- componente importável por outro site Antora;
- site Antora executável localmente;
- geração de HTML, PDF e EPUB.

Priorize conteúdo, caminhos previsíveis e pouca infraestrutura. Leia `README.adoc` antes de agir e preserve alterações preexistentes do usuário.

## Fontes de verdade

- `modules/`: conteúdo reconhecido pelo Antora.
- `modules/ROOT/pages/index.adoc`: apresentação da publicação.
- `modules/ROOT/assets/`: recursos compartilhados e capas.
- `modules/<módulo>/nav.adoc`: navegação Antora da edição.
- `antora.yml`: componente, página inicial e módulos de navegação.
- `antora-playbook.yml`: execução local do site.
- `asciidoctor/publication.yml`: autor, identificador, títulos, slugs, idiomas e edições.
- `asciidoctor/contents.adoc`: ordem do HTML, PDF e EPUB.
- `asciidoctor/support/attributes/common.adoc`: atributos compartilhados.
- `asciidoctor/support/attributes/<idioma>.adoc`: traduções dos rótulos do Asciidoctor.
- `asciidoctor/support/publication.adoc` e `asciidoctor/support/themes/`: infraestrutura comum das publicações.

Não coloque identidade editorial no `Rakefile`, em `package.json` ou em `asciidoctor/support`.

## Criar outra publicação

Ao substituir o conteúdo deste modelo:

1. Atualize a tabela e a seção Sobre do `README.adoc` e de `modules/ROOT/pages/index.adoc`.
2. Substitua `modules/main/pages/` e reconstrua `modules/main/nav.adoc`; renomeie o módulo se a publicação exigir uma identificação mais específica.
3. Atualize `antora.yml`, `antora-playbook.yml` e `asciidoctor/publication.yml`.
4. Reconstrua `asciidoctor/contents.adoc` na ordem editorial correta.
5. Substitua as capas em `modules/ROOT/assets/images/`.
6. Remova todas as referências, imagens, títulos e slugs da publicação anterior.
7. Execute Antora e Asciidoctor antes de considerar o trabalho concluído.

`main` é somente o módulo neutro inicial. Quando houver variedades da publicação, use nomes que expressem a dimensão organizada:

- idiomas: `en-us`, `pt-br`;
- edições: `primeira-edicao`, `segunda-edicao`;
- combinação necessária: `pt-br-primeira-edicao`.

Use slugs ASCII minúsculos e uma convenção consistente. Para cada módulo, a chave em `publication.yml` deve ser idêntica ao diretório em `modules/`. O valor `lang`, como `pt-BR`, seleciona o perfil `pt-br.adoc`; o nome do módulo não substitui esse campo.

Ao renomear um módulo, atualize o diretório, `antora.yml`, `publication.yml`, o `nav.adoc` e todos os `xref` que mencionem o nome anterior. Preserve os mesmos nomes de página quando os conteúdos forem correspondentes.

Edite arquivos de infraestrutura somente quando a solicitação tratar da forma de executar ou publicar o projeto.

## Conteúdo e nomenclatura

Antes de criar ou atualizar conteúdo preparado para busca ou conversa com
inteligência artificial, leia integralmente
[AGENTS-RAG.md](AGENTS-RAG.md). Esse arquivo define a pasta `rag/`, os corpora,
as coordenadas de origem, o chunking, os resumos e a geração determinística
compartilhada com as demais famílias `Docs.*`.

Use:

```text
NNNN-slug-descritivo.adoc
```

Regras:

- quatro dígitos, preferencialmente em intervalos de dez;
- slug ASCII minúsculo com números e hífens;
- sem espaços, acentos, sublinhados ou pontuação;
- ordenação pelo nome igual à ordem natural da publicação;
- mesmos caminhos para páginas correspondentes entre edições.

Exemplo:

```text
0010-prefacio.adoc
0100-capitulo-01-titulo.adoc
0110-capitulo-02-titulo.adoc
```

No título AsciiDoc de um capítulo, escreva somente o título. Deixe número e rótulo explícitos no `nav.adoc`:

```adoc
= Um capítulo de exemplo
```

```adoc
* xref:0100-capitulo-01-exemplo.adoc[Capítulo 1 - Um capítulo de exemplo]
```

Sempre atualize `nav.adoc` e `asciidoctor/contents.adoc` ao adicionar, remover, renomear ou reordenar páginas.

## Recursos e capas

Compartilhe imagens entre edições por meio de `modules/ROOT/assets/images/`. Use nomes slug em ASCII e valide as referências no Antora.

Preserve a função destes arquivos:

- `cover-complete.png`: capa pronta do PDF e do EPUB;
- `cover-background.png`: página de título do PDF;
- `cover-banner.png`: apresentação inicial do HTML.

Não inclua páginas artificiais de capa ou sumário em `contents.adoc`; os conversores geram esses elementos.

## Infraestrutura

- Preserve `:doctype: book`; é o tipo técnico do Asciidoctor.
- Mantenha `asciidoctor/support` reutilizável entre repositórios.
- Mantenha `package.json` genérico; versões editoriais são tags Git.
- Não versione `build/` nem `node_modules/`.
- Atualize lockfiles somente junto com mudanças de dependências.
- Não acrescente bibliotecas, serviços, temas ou automações sem necessidade explícita.
- Não crie commits, tags, releases ou pushes sem autorização explícita.

## Validação

Execute:

```shell
npm exec -- antora antora-playbook.yml
bundle exec rake
```

Confirme:

- ausência de referências ou inclusões quebradas;
- HTML, PDF e EPUB para todas as edições;
- ordem definida em `contents.adoc`;
- rótulos no idioma selecionado;
- três capas aplicadas aos destinos esperados;
- somente mudanças intencionais no `git status`.

## Releases

O workflow `.github/workflows/release.yml` responde a tags anotadas `vX.Y.Z` e publica os formatos gerados. Antes de sugerir uma versão, compare a última tag com o estado atual e proponha número e mensagem objetivos.

Não crie ou envie uma tag sem autorização. Depois de publicada, não mova, apague ou reutilize a tag e não reescreva os commits alcançados por ela.
