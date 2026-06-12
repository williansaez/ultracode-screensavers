# Ultracode Screensavers

Suite de **15 screensavers nativos para macOS** com a estética "ultracode" do Claude Code: grelha de quadradinhos arredondados sobre fundo escuro, com brilho lavanda — cada saver é uma simulação ou visualização diferente a viver nessa grelha.

Tudo escrito em Swift puro (`ScreenSaverView`), sem dependências, compilado com o toolchain de linha de comandos.

## Opções comuns

Todos os savers partilham o mesmo painel de **Opções…** nas Definições de Proteção de Ecrã:

| Opção | Descrição |
|---|---|
| **Tema** | Ultracode (lavanda) · Doom clássico (fogo) · Matrix (verde) |
| **Espaçamento da grelha** | Slider com posições fixas — só valores em que nenhuma célula fica cortada nas bordas do ecrã |
| **Velocidade** | fps (ou unidade própria do saver, ex.: gerações/s) |
| **Brilho do fundo** | Brilho das células apagadas (0 = grelha invisível) |
| **Bloom** | Brilho/glow nas células de destaque |

**Regra de cor de acento** — elementos que precisam de contraste (predador, comida, bola, caminho-solução, núcleo) usam a cor de acento do tema: lavanda → amarelo `#FFD60A` · Doom → azul `#3A8DFF` · Matrix → vermelho `#FF453A`. (Exceção: **Bateria** usa as cores padrão Apple e não tem tema.)

## Os savers

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
  build.sh                 # compila + assina + instala tudo
screenshots/               # capturas usadas neste README
variant_*.png              # wallpapers estáticos 3024×1964 com a mesma estética
```

Cada saver tem um harness offline que instancia a view, bombeia frames e grava PNGs — é assim que tudo é verificado visualmente sem instalar.

## Notas de implementação

- O sheet de opções usa frames fixos (autolayout colapsa quando o `legacyScreenSaver` apresenta o sheet remotamente nas Definições).
- O slider de espaçamento é um slider de índice sobre a lista de valores sem células cortadas, calculada para o ecrã principal.
- Tudo é desenhado em células exatas da malha — nada de posições contínuas sobrepostas à grelha.
