# Instruções para agentes de inteligência artificial

## Objetivo

Este é um modelo de publicação bíblica em AsciiDoc com três usos:

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

## Criar outra Bíblia

Ao substituir o conteúdo deste modelo:

1. Atualize a tabela e a seção Sobre do `README.adoc` e de `modules/ROOT/pages/index.adoc`.
2. Escolha uma edição de referência e substitua `modules/main/pages/`; crie outros módulos quando houver edições ou idiomas adicionais.
3. Atualize `nav.adoc`, `antora.yml`, `antora-playbook.yml` e `asciidoctor/publication.yml`.
4. Reconstrua `asciidoctor/contents.adoc` na ordem canônica.
5. Ajuste a quantidade e a ordem dos livros quando o cânon for diferente.
6. Substitua as capas em `modules/ROOT/assets/images/`.
7. Remova todas as referências, imagens, títulos e slugs da publicação anterior.
8. Execute Antora e Asciidoctor antes de considerar o trabalho concluído.

`main` é o módulo neutro inicial. Para cada módulo, mantenha idênticos o diretório em `modules/` e a chave em `publication.yml`. O campo `lang`, como `pt-BR`, seleciona o perfil de idioma; preserve os mesmos caminhos nas edições correspondentes.

## Conteúdo e nomenclatura

Antes de criar ou atualizar conteúdo preparado para busca ou conversa com
inteligência artificial, leia integralmente
[AGENTS-RAG.md](AGENTS-RAG.md). Esse arquivo define a pasta `rag/`, os corpora,
as coordenadas de origem, o chunking, os resumos e a geração determinística
compartilhada com as demais famílias `Docs.*`.

Use esta estrutura:

```text
modules/<módulo>/pages/NNN-slug-do-livro/index.adoc
modules/<módulo>/pages/NNN-slug-do-livro/NNN-slug-do-livro-NNN.adoc
```

Regras:

- três dígitos para ordenar livros e capítulos;
- slug ASCII minúsculo com números e hífens;
- um `index.adoc` por edição e por livro;
- um arquivo autônomo por capítulo, iniciado por `= `;
- mesmos caminhos para conteúdos correspondentes entre edições;
- cânon e ordem derivados da publicação, sem fixá-los em 66 livros.

Preserve âncoras de livro, capítulo e versículo. Não coloque navegação anterior/topo/próximo dentro dos capítulos; navegação é estrutura, não texto bíblico. Sempre atualize `nav.adoc` e `asciidoctor/contents.adoc` ao adicionar, remover, renomear ou reordenar páginas.

## Navegação Antora

O `nav.adoc` de cada edição deve listar a edição e seus livros, mas não todos os capítulos. A página de cada livro fornece uma tabela compacta de capítulos.

- Condicione tabelas exclusivamente navegacionais com `ifdef::env-site[]`.
- Preserve `page-bible-navigation`, `bible-navigation.cjs` e `bible-sidebar.js`; eles geram os seletores sem reescrever o conteúdo e mantêm o livro aberto no menu.
- Em outro site Antora, registre uma extensão compatível; o playbook agregador não importa automaticamente a extensão local.

## Recursos e capas

Compartilhe imagens entre edições por meio de `modules/ROOT/assets/images/`. Use nomes slug em ASCII e valide as referências no Antora.

Preserve a função destes arquivos:

- `cover-complete.png`: capa pronta do PDF e do EPUB;
- `cover-background.png`: página de título do PDF;
- `cover-banner.png`: apresentação inicial do HTML.

Não inclua páginas artificiais de capa ou sumário em `contents.adoc`; os conversores geram esses elementos.

## Infraestrutura

- Preserve `:doctype: book`; é o tipo técnico do Asciidoctor.
- Mantenha `toclevels` em `1` e a numeração automática desabilitada para limitar o sumário aos livros.
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
- quantidade e ordem esperadas de livros e capítulos;
- mesmos caminhos nas edições correspondentes;
- sumário limitado aos livros;
- HTML, PDF e EPUB para todas as edições;
- somente mudanças intencionais no `git status`.

## Releases

O workflow `.github/workflows/release.yml` responde a tags anotadas `vX.Y.Z` e publica os formatos gerados. Antes de sugerir uma versão, compare a última tag com o estado atual e proponha número e mensagem objetivos.

Não crie ou envie uma tag sem autorização. Depois de publicada, não mova, apague ou reutilize a tag e não reescreva os commits alcançados por ela.
