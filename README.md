# Ultracode Screensavers

Suite de **22 screensavers nativos para macOS** em duas famílias:

- **Suite ultracode (15)** — estética do Claude Code: grelha de quadradinhos arredondados sobre fundo escuro, com brilho lavanda; cada saver é uma simulação ou visualização a viver nessa grelha.
- **Réplicas originkit (7)** — portes fiéis de componentes web animados do [originkit.dev](https://www.originkit.dev) (preset `base`), pixel a pixel e equação a equação.

Tudo escrito em Swift puro (`ScreenSaverView`), sem dependências, compilado com o toolchain de linha de comandos.

## Opções comuns

### Suite ultracode

Painel de **Opções…** partilhado nas Definições de Proteção de Ecrã:

| Opção | Descrição |
|---|---|
| **Tema** | Ultracode (lavanda) · Doom clássico (fogo) · Matrix (verde) · Mono (branco sobre preto, look das réplicas) |
| **Espaçamento da grelha** | Slider com posições fixas — só valores em que nenhuma célula fica cortada nas bordas do ecrã |
| **Velocidade** | fps (ou unidade própria do saver, ex.: gerações/s) |
| **Brilho do fundo** | Brilho das células apagadas (0 = grelha invisível) |
| **Bloom** | Brilho/glow nas células de destaque |

**Regra de cor de acento** — elementos que precisam de contraste (predador, comida, bola, caminho-solução, núcleo) usam a cor de acento do tema: lavanda → amarelo `#FFD60A` · Doom → azul `#3A8DFF` · Matrix → vermelho `#FF453A` · Mono → laranja `#E07000`. (Exceção: **Bateria** usa as cores padrão Apple e não tem tema.)

### Réplicas originkit

Cada réplica tem a sua folha de opções: **Tema** (Base = visual original · Lavanda · Doom · Matrix), **Velocidade** (0.25×–3×) e extras próprios (indicados em cada saver abaixo). Nos temas coloridos o tom é uniforme; quando há destaque, vem da dinâmica (ex.: velocidade de rotação), nunca de gradientes espaciais.

## Suite ultracode

### Ultracode (fogo do Doom)
Algoritmo de fogo do PSX Doom: fonte de calor na base, propagação com decaimento aleatório. Opções extra: altura das chamas e intensidade.

![Ultracode lavanda](screenshots/ultracode_1.png)
![Ultracode Doom](screenshots/ultracode_2.png)

### Jogo da Vida (Conway)
B3/S23 toroidal com idade: recém-nascidas brilhantes, mortas deixam rasto. Reseed automático quando o mundo estagna.

![Vida](screenshots/vida_1.png)
![Vida mais tarde](screenshots/vida_2.png)

### Bolor Limoso (Physarum)
Space-colonization a partir de um ponto de inoculação: a rede dendrítica cresce até à "comida" espalhada pelo ecrã, com troncos brilhantes e pontas ténues; dissolve e renasce noutro ponto.

![Bolor a crescer](screenshots/bolor_1.png)
![Bolor rede completa](screenshots/bolor_2.png)

### Processador
Barras por núcleo de CPU em tempo real (mach `host_processor_info`).

![CPU em carga](screenshots/processador_1.png)
![CPU idle](screenshots/processador_2.png)

### Rede
Chuva digital movida pelo tráfego real (`getifaddrs`): download cai do topo, upload sobe de baixo; densidade segue o débito em escala log.

![Rede streaming](screenshots/rede_1.png)
![Rede tráfego pesado](screenshots/rede_2.png)

### Bateria
Medidor sólido: cada célula é uma fatia fixa de carga (leitura crua em mAh via IORegistry). Verde normal/a carregar, amarelo em Low Power Mode, vermelho ≤20%. A célula de fronteira pisca como lâmpada a queimar antes de apagar.

![Bateria 85%](screenshots/bateria_1.png)
![Bateria fraca](screenshots/bateria_2.png)

### Relógio
HH:MM gigante desenhado nas células (fonte 5×7), dois-pontos a piscar; o minuto muda com dissolve aleatório.

![Relógio](screenshots/relogio_1.png)
![Relógio em transição](screenshots/relogio_2.png)

### Reação-Difusão
Gray-Scott (F=0.037, k=0.06): padrões de Turing orgânicos que crescem e morfam para sempre.

![Gray-Scott](screenshots/reacao_difusao_1.png)
![Gray-Scott labirinto](screenshots/reacao_difusao_2.png)

### Boids
Bando proporcional ao tamanho da grelha com rastos de cometa; a cada ~15 s um predador (cor de acento) espalha o bando.

![Boids](screenshots/boids_1.png)
![Boids a fugir do predador](screenshots/boids_2.png)

### Labirinto
Gera (backtracker animado) → resolve (BFS) → caminho ilumina-se na cor de acento → dissolve → repete.

![Labirinto a gerar](screenshots/labirinto_1.png)
![Labirinto resolvido](screenshots/labirinto_2.png)

### Relâmpagos
Raios ramificados descem em passeio aleatório; ao tocar o fundo, flash do canal inteiro e desvanecimento.

![Relâmpago a crescer](screenshots/relampagos_1.png)
![Relâmpago no flash](screenshots/relampagos_2.png)

### Areia
Autómato de areia: emissores em deriva, dunas com estratos coloridos; quando o ecrã enche, abre um dreno e os estratos afundam.

![Areia dunas](screenshots/areia_1.png)
![Areia no dreno](screenshots/areia_2.png)

### Snake
IA auto-jogada (BFS para a comida + perseguição da cauda para sobreviver); comida na cor de acento; só reinicia quando perde.

![Snake](screenshots/snake_1.png)
![Snake longa](screenshots/snake_2.png)

### Pong
Dois AIs com erro de reação humano — falham um rally de vez em quando; bola na cor de acento com cauda de cometa.

![Pong](screenshots/pong_1.png)
![Pong no ponto](screenshots/pong_2.png)

### Átomo
Modelo de Rutherford: núcleo-aglomerado de protões (cor de acento, 1 protão por eletrão) e eletrões em elipses com precessão. Começa como hidrogénio; a cada 6–12 s chega um eletrão de fora do ecrã; no limite, um é ejetado.

![Átomo hidrogénio](screenshots/atomo_1.png)
![Átomo multi-camada](screenshots/atomo_2.png)

## Réplicas originkit

### Ondas Cromáticas
Halftone animado (Metal): grelha de discos cujo raio segue um campo de ruído simplex — port do shader WebGL, dois passes fundidos num só fragment. Extras: tamanho de célula, frequência.

![Ondas Cromáticas](screenshots/ondas_cromaticas_1.png)
![Ondas Cromáticas mais tarde](screenshots/ondas_cromaticas_2.png)

### Onda de Texto
Grelha de caracteres com opacidade modulada por onda + jitter de ruído (movimento orgânico, não repetitivo). Extras: **texto personalizável**, dose de ruído.

![Onda de Texto](screenshots/onda_texto_1.png)
![Onda de Texto noutra fase](screenshots/onda_texto_2.png)

### Esfera de Partículas
10 000 partículas em espiral de Fibonacci (Metal, additive blending) com o moiré característico; nos temas, a cor segue a profundidade (trás frio → frente quente). Extras: nº de partículas (2k–20k), tamanho.

![Esfera de Partículas](screenshots/esfera_particulas_1.png)
![Esfera rodada](screenshots/esfera_particulas_2.png)

### Globo
Dot-globe com continentes reais (Natural Earth embutido, ~15k dots) e **bolinha verde na tua posição atual** — obtida do fuso horário (`zone.tab`), offline e sem permissões. Extras: densidade de dots, mostrar/ocultar posição.

![Globo](screenshots/globo_1.png)
![Globo rodado](screenshots/globo_2.png)

### Cartão de Píxeis
Céu estrelado de micro-píxeis: entrada em varrimento radial e shimmer perpétuo com fase aleatória (nunca termina, nunca pulsa em anéis). Extras: gap, tamanho do píxel.

![Cartão de Píxeis](screenshots/cartao_pixeis_1.png)
![Cartão de Píxeis mais tarde](screenshots/cartao_pixeis_2.png)

### Matriz de Pontos
Halftone laranja de blobs de ruído simplex 3D (port exato do shader Ashima). Extras: tamanho de célula, contraste da paleta (bias baixo deixa o branco entrar).

![Matriz de Pontos](screenshots/matriz_pontos_1.png)
![Matriz de Pontos mais tarde](screenshots/matriz_pontos_2.png)

### Ondulação de Linhas
Flow field de traços curtos orientados por ruído simplex em deriva; nos temas, tom uniforme com traços a **acender conforme a velocidade de rotação**. Extras: densidade, comprimento do traço.

![Ondulação de Linhas](screenshots/ondulacao_linhas_1.png)
![Ondulação de Linhas noutra fase](screenshots/ondulacao_linhas_2.png)

## Pré-visualização sem Definições

```bash
cd screensaver
./preview.sh UltracodeGlobe        # um saver numa janela (Esc fecha)
./preview.sh UltracodeAtom 10      # fecha sozinho após 10 s
./gallery.sh                       # galeria: ←→ muda · C abre as opções · Esc sai
./gallery.sh --auto 5              # slideshow dos 22, um a cada 5 s
```

A galeria carrega os bundles compilados e a tecla **C** abre a folha de opções do saver visível — OK aplica e reinicia na hora.

## Instalação

Requisitos: macOS 12+, Xcode Command Line Tools (`xcode-select --install`), Apple Silicon.

```bash
cd screensaver
./build.sh --install
```

Depois: **Definições do Sistema → Papel de parede / Proteção de ecrã → secção "Outros"**.

> Os bundles são assinados ad-hoc. Os savers correm no `legacyScreenSaver` do macOS; depois de reinstalar, o script reinicia o agente para limpar o cache. Se a pré-visualização não atualizar, fecha e reabre as Definições do Sistema.

## Estrutura

```
screensaver/
  Ultracode*View.swift     # um ficheiro por saver
  *.saver/Contents/        # bundles (Info.plist no git; binário é gerado)
  *_test/main.swift        # harness offline de cada saver (renderiza PNGs sem instalar)
  refs/<nome>/source_*.tsx # fontes originais dos componentes originkit (para fidelidade)
  build.sh                 # compila + assina + instala tudo
  preview.sh               # um saver numa janela
  gallery.sh               # galeria navegável com acesso às opções
screenshots/               # capturas usadas neste README
variant_*.png              # wallpapers estáticos 3024×1964 com a mesma estética
```

Cada saver tem um harness offline que instancia a view, bombeia frames e grava PNGs — é assim que tudo é verificado visualmente sem instalar.

## Notas de implementação

- O sheet de opções usa frames fixos (autolayout colapsa quando o `legacyScreenSaver` apresenta o sheet remotamente nas Definições).
- O slider de espaçamento é um slider de índice sobre a lista de valores sem células cortadas, calculada para o ecrã principal.
- Na suite ultracode tudo é desenhado em células exatas da malha — nada de posições contínuas sobrepostas à grelha. (As réplicas originkit não seguem a grelha: reproduzem o rendering do componente original, incluindo Metal onde a referência usa WebGL.)
- Interações de rato dos componentes originais (hover, drag) foram substituídas por ciclos autónomos mantendo a física — um screensaver termina ao primeiro toque no rato.
- A posição do Globo vem de `/usr/share/zoneinfo/zone.tab` (cidade do fuso horário): offline, sem CoreLocation nem prompts de privacidade dentro do saver.
