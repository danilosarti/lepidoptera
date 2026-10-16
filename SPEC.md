# lepidoptera — Especificação do Package

Versão do documento: 0.1 (rascunho fundacional)
Status: proposta para validação — sem código implementado ainda
Implementações previstas: R e Python, em paralelo, com paridade de API

---

## 1. Visão geral

`lepidoptera` é um motor de simulação genérico e versátil. Ele não modela nenhum domínio específico — não sabe nada sobre epidemiologia, economia, biologia, etc. O que ele sabe fazer é:

1. Representar um **sistema** como um conjunto de **features** (variáveis) com tipos heterogêneos (contínuas, categóricas, ordinais).
2. Representar **dependências a priori** entre essas features como um grafo.
3. Definir, para cada dependência, um **mecanismo** (função/regra) que descreve como o valor de uma feature é gerado a partir dos valores de suas features-pais.
4. Gerar (simular) populações de unidades a partir desse sistema.
5. Aplicar **intervenções** sobre uma ou mais features e **propagar** o efeito dessas intervenções pela estrutura de dependências, recalculando tudo que é afetado a jusante (downstream).

A ideia de longo prazo é que `lepidoptera` seja a camada de infraestrutura ("backstage") sobre a qual soluções de simulação específicas de domínio são construídas depois — sem precisar reinventar a parte de representação de dependências, tipos mistos e propagação de intervenções a cada novo projeto.

### 1.1 Princípios de design

- **Agnóstico de domínio.** Nada no core sabe o que uma feature "significa". Semântica de domínio é responsabilidade de quem usa o package por cima.
- **Tipos mistos como cidadãos de primeira classe.** Contínuo, categórico e ordinal devem ser suportados em qualquer combinação pai→filho, sem tratamento especial em código de usuário.
- **Estrutura explícita, mecanismo explícito.** O grafo de dependências e as regras de geração de valores são objetos de primeira classe, inspecionáveis e serializáveis — não funções anônimas escondidas.
- **Intervenção como operação central.** O sistema não serve só para "rodar uma simulação", mas para perguntar "o que muda se eu intervier aqui?" — isso precisa ser barato e bem definido.
- **Paridade R/Python.** As duas implementações compartilham o mesmo modelo conceitual, os mesmos nomes de função (adaptados à convenção idiomática de cada linguagem) e devem produzir resultados equivalentes dado o mesmo seed.
- **v1 simples, v2 extensível.** A primeira versão assume grafo acíclico (DAG) com propagação one-shot. A arquitetura é desenhada para depois suportar dinâmica temporal e feedback loops sem quebrar a API de v1.

### 1.2 Fora de escopo (por ora)

- Inferência causal a partir de dados observacionais (descoberta de estrutura). `lepidoptera` assume que a estrutura de dependência é fornecida pelo usuário, não a descobre.
- Otimização/calibração automática de parâmetros dos mecanismos.
- Interface gráfica. O foco é a biblioteca/engine; visualização é tratada como utilitário secundário (ex.: plot do grafo), não como produto.
- Simulação distribuída/paralela em larga escala (pode vir depois, não é requisito de v1).

---

## 2. Conceitos centrais

| Conceito | Definição |
|---|---|
| **Feature** | Uma variável do sistema. Tem nome, tipo (contínua, categórica ou ordinal) e um domínio. |
| **Domínio** | Para contínua: intervalo (com possíveis limites). Para categórica: conjunto finito de níveis sem ordem. Para ordinal: conjunto finito de níveis com ordem. |
| **Grafo de dependência** | Um grafo dirigido cujos nós são features. Uma aresta `A → B` significa "B depende de A" (A é pai de B). v1: exige-se que o grafo seja acíclico (DAG). |
| **Mecanismo** | A regra associada a uma feature que, dados os valores correntes de seus pais (e possivelmente um termo de ruído), determina o valor (ou a distribuição do valor) dessa feature. Features sem pais (raízes) têm um mecanismo marginal (uma distribuição base, sem inputs). |
| **Sistema (System/Model)** | O conjunto completo: features + grafo de dependência + mecanismos associados a cada feature. É a "especificação" simulável. |
| **Unidade** | Uma realização simulada do sistema — um vetor com um valor para cada feature, gerado seguindo a ordem topológica do grafo. |
| **População** | Um conjunto de N unidades simuladas independentemente a partir do mesmo sistema. Representada como uma tabela (data frame): linhas = unidades, colunas = features. |
| **Intervenção** | Uma modificação aplicada a uma ou mais features do sistema (ex.: fixar um valor, deslocar uma distribuição, substituir um mecanismo) antes de gerar/regenerar a população. |
| **Propagação** | O processo de recalcular, em ordem topológica, todas as features afetadas direta ou indiretamente por uma intervenção, mantendo intactas as features não afetadas (ou recalculando-as de forma consistente quando há resampling completo). |
| **Resultado de simulação** | O artefato comparável: população baseline vs. população pós-intervenção, mais metadados (quais features foram alteradas, em que ordem a propagação ocorreu). |

---

## 3. Modelo de dados

Esta seção descreve as entidades de forma language-agnostic. A seção 7 mapeia cada entidade para classes/funções concretas em R e Python.

### 3.1 `FeatureType`

Enumeração fechada: `continuous`, `categorical`, `ordinal`.

### 3.2 `FeatureSpec`

Campos:

- `name: string` — identificador único dentro do sistema.
- `type: FeatureType`
- `domain`: depende do tipo —
  - contínua: `{min, max}` (podem ser infinitos)
  - categórica: `{levels: [string, ...]}` (sem ordem)
  - ordinal: `{levels: [string, ...]}` (a ordem da lista define a ordem da escala)
- `metadata: dict` opcional — espaço livre para anotações de quem usa o package (rótulos legíveis, unidades, descrição), nunca interpretado pelo core.

### 3.3 `Mechanism`

Um mecanismo é a função geradora associada a uma feature. Dois tipos:

- **Marginal mechanism** (para features-raiz, sem pais): uma distribuição/regra que não recebe inputs, só um gerador de números aleatórios (RNG) e parâmetros. Ex.: Normal(μ, σ) para contínua; distribuição categórica com vetor de probabilidades; distribuição multinomial ordenada para ordinal.
- **Conditional mechanism** (para features com ≥1 pai): uma função `f(parent_values, rng, params) -> value` (ou `-> distribuição`, da qual se amostra o valor). A assinatura recebe os valores correntes de **todos** os pais declarados na aresta, na forma de seus tipos nativos (número para contínua, string/fator para categórica e ordinal).

Cada mecanismo declara explicitamente:
- `output_type`: deve ser compatível com o tipo da feature à qual pertence.
- `parent_types`: os tipos esperados de cada pai (usado para validação na hora de montar o sistema, não em tempo de simulação).

O core fornece uma **biblioteca de mecanismos pré-fabricados** cobrindo as combinações de tipo mais comuns (ver seção 4), e permite que o usuário registre mecanismos customizados (uma função qualquer respeitando a assinatura).

### 3.4 `DependencyEdge`

- `from: FeatureSpec.name` (pai)
- `to: FeatureSpec.name` (filho)

Uma feature pode ter múltiplos pais; nesse caso, o `Mechanism` da feature filha recebe todos os valores dos pais de uma vez (não há composição implícita aresta-a-aresta — o mecanismo é por nó, não por aresta).

### 3.5 `System`

- `features: {name -> FeatureSpec}`
- `edges: [DependencyEdge, ...]`
- `mechanisms: {name -> Mechanism}` — uma entrada por feature.
- Invariantes validados na construção/finalização do sistema:
  1. Toda feature tem exatamente um mecanismo.
  2. O grafo induzido por `edges` é acíclico (v1).
  3. Toda feature referenciada em uma aresta existe em `features`.
  4. O `parent_types` de cada mecanismo condicional é consistente com os tipos reais dos pais declarados nas arestas.
  5. Toda feature tem ao menos um caminho de geração válido (raízes têm mecanismo marginal; não-raízes têm mecanismo condicional cobrindo exatamente seus pais).

### 3.6 `Intervention`

- `target: feature name (ou lista de features)`
- `kind`: um de
  - `do_fix`: fixa a feature em um valor constante para todas as unidades (do-operator clássico), desconectando-a de seus pais.
  - `do_distribution`: substitui o mecanismo marginal/condicional por uma nova distribuição/função, mantendo ou não a dependência dos pais.
  - `shift`: aplica um deslocamento/transformação sobre o valor que seria gerado pelo mecanismo original (ex.: +Δ para contínua, remapeamento de níveis para categórica/ordinal), preservando a dependência dos pais.
  - `mechanism_override`: substitui completamente o `Mechanism` de uma feature por outro, arbitrário.
- `params`: dados específicos do tipo de intervenção (valor fixo, nova distribuição, função de shift, novo mecanismo).

Intervenções são objetos imutáveis aplicados sobre uma cópia do sistema (nunca mutam o sistema original in-place) — isso permite comparar baseline e intervenção a partir da mesma especificação base.

### 3.7 `Population`

Uma tabela com uma linha por unidade simulada e uma coluna por feature, mais uma coluna implícita de id de unidade. Tipagem de coluna reflete o `FeatureType` (numérica para contínua; fator/categoria para categórica e ordinal, preservando a ordem declarada no caso ordinal).

### 3.8 `SimulationResult`

- `baseline: Population`
- `intervened: Population` (mesmo número de unidades e mesmo seed-base que `baseline`, para permitir comparação pareada unidade-a-unidade quando aplicável)
- `interventions: [Intervention, ...]` aplicadas
- `affected_features: [name, ...]` — fecho transitivo a jusante das features-alvo das intervenções, na ordem em que foram recalculadas
- `propagation_order: [name, ...]` — ordem topológica usada

---

## 4. Tipos de variável e combinações de dependência

O requisito central é: qualquer combinação tipo-do-pai → tipo-do-filho precisa ser suportável. Isso dá 9 combinações binárias (3 tipos × 3 tipos), mais o caso de múltiplos pais de tipos diferentes para um único filho.

| Pai → Filho | Estratégia padrão fornecida pelo core |
|---|---|
| Contínuo → Contínuo | Função paramétrica (linear, polinomial, etc.) + ruído aditivo configurável. |
| Contínuo → Categórico | Modelo tipo regressão multinomial: contínuo é mapeado a probabilidades por nível (ex.: via função softmax sobre combinação linear dos pais). |
| Contínuo → Ordinal | Modelo tipo regressão ordinal (logito cumulativo / proportional odds): contínuo desloca os cortes (thresholds) entre níveis ordenados. |
| Categórico → Contínuo | Cada nível do pai associado a um efeito (média/parâmetro) diferente sobre a distribuição contínua do filho (equivalente a um "efeito de grupo"). |
| Categórico → Categórico | Tabela de transição / matriz de probabilidades condicionais nível-a-nível. |
| Categórico → Ordinal | Cada nível do pai categórico associado a uma distribuição diferente sobre os níveis ordenados do filho. |
| Ordinal → Contínuo | Ordinal é tratado com seu código numérico (posição na escala) e tratado como pseudo-contínuo na função geradora, OU efeito por nível como no caso categórico → contínuo (escolha do usuário). |
| Ordinal → Categórico | Análogo a categórico → categórico, com a opção de o usuário aproveitar a ordem (ex.: probabilidades monotônicas) se desejar. |
| Ordinal → Ordinal | Tabela de transição respeitando (opcionalmente) monotonicidade na propagação. |
| Múltiplos pais mistos → Filho (qualquer tipo) | O mecanismo recebe o vetor completo de valores dos pais (cada um em seu tipo nativo) e é responsabilidade do mecanismo combinar os efeitos. O core fornece um helper de "codificação de pais mistos" (dummy/one-hot para categóricas, código inteiro para ordinais, valor bruto para contínuas) para quem quiser montar uma combinação linear/aditiva genérica em vez de escrever a lógica de combinação à mão. |

Importante: o core **não obriga** o uso desses mecanismos pré-fabricados. Eles existem como conveniência (cobrem o caso comum sem o usuário ter que escrever uma função estatística do zero). Qualquer mecanismo customizado que respeite a assinatura de `Mechanism` é válido.

### 4.1 Mecanismo de cópula (vine copulas)

Além das estratégias ad-hoc da tabela acima, `lepidoptera` oferece um **mecanismo de cópula** como motor de dependência de uso geral, cobrindo toda a família de cópulas fornecida pelo `rvinecopulib` sem reimplementar nada do zero.

**Quando usar.** O mecanismo de cópula modela a dependência conjunta entre um conjunto de features (um nó e seus pais) de uma vez, em vez de uma função determinística pai→filho. Dado o valor dos pais de uma unidade, o valor do filho é obtido por **amostragem condicional** dentro da vine.

---

#### 4.1.1 Back-ends e roteamento de famílias

`copula_mechanism()` possui dois caminhos de execução:

| `family =` | Back-end | Pacotes extras |
|---|---|---|
| `"gaussian"` | Cópula Gaussiana pura em base R (correlação de Spearman via escores normais) | nenhum |
| `"auto"` | **rvinecopulib** com seleção automática de família por AIC (todos os pares); se o pacote não estiver instalado, cai para Gaussiana silenciosamente | `rvinecopulib` (Suggests) |
| qualquer outro valor | **rvinecopulib** com a família/conjunto especificado | `rvinecopulib` obrigatório |

---

#### 4.1.2 Famílias suportadas (rvinecopulib)

`vinecopulib` cobre mais de 20 famílias bivariadas paramétricas, montadas em **vine copulas** (D-vine no caso multivariado) para dependência conjunta em qualquer dimensão.

| Categoria | Família | `family =` |
|---|---|---|
| Gaussiana (base R) | Gaussiana | `"gaussian"` |
| Elíptica | t de Student | `"t"` |
| Arquimediana simétrica | Frank | `"frank"` |
| Arquimediana (cauda inferior) | Clayton | `"clayton"` |
| Arquimediana (cauda superior) | Gumbel, Joe | `"gumbel"`, `"joe"` |
| Bi-paramétricas | BB1, BB6, BB7, BB8 | `"bb1"`, `"bb6"`, `"bb7"`, `"bb8"` |
| Rotações (90°/180°/270°) | Qualquer Archimediana rotacionada | `"clayton90"`, `"gumbel180"`, … |
| Não-paramétrica | Kernel (TLL) | `"tll"` |
| Meta-conjuntos | Seleciona o melhor entre um grupo | `"onepar"`, `"twopar"`, `"parametric"`, `"all"` |
| Seleção automática | Melhor família por par via AIC | `"auto"` |

`list_copula_families()` retorna o vetor completo de nomes aceitos pela instalação corrente.

---

#### 4.1.3 Simulação condicional — método Rosenblatt

Para gerar `u_child | u_parents` via uma vine copula, `lepidoptera` usa a **transformada de Rosenblatt** disponível em `rvinecopulib`:

**Convenção de ordenação.** As variáveis são dispostas na matriz de pseudo-observações como `c(parents..., child)` — o filho **sempre na última coluna**. Uma D-vine com a ordem `1, 2, …, d` garante que:
```
v[i]   = F(u_i | u_1, ..., u_{i-1})    # depende apenas das colunas à esquerda
v[d]   = F(u_child | u_parents)        # condicional que queremos amostrar
```

**Algoritmo (multivariado, d ≥ 3):**
1. Montar `u_row = [u_p1, …, u_pk, 0.5]` (placeholder `0.5` para o filho — não afeta colunas anteriores na D-vine).
2. `v_row = rosenblatt(u_row, vine_obj)`.
3. Substituir `v_row[k+1] ← runif(1)` — sorteio fresco e independente.
4. `u_new = inverse_rosenblatt(v_row, vine_obj)`.
5. `u_child = u_new[k+1]` — marginal condicional corretamente amostrada.

**Algoritmo (bivariado, d = 2):**
Usa `hbicop(matrix(c(u_parent, v_child), 1), bicop_obj, cond_var=1, inverse=TRUE)` — inversão exata da h-função.

**Decodificação.** `u_child ∈ (0,1)` é convertido ao domínio original via ECDF inversa (tabela de rank-ECDF estimada em `fit_data`).

---

#### 4.1.4 Assinatura R

```r
copula_mechanism(
  variables,                              # c(child, parent1, parent2, ...)
  family           = "gaussian",          # ver tabela 4.1.2
  marginals        = "auto",             # "auto" = ECDF empírica (rank-based)
  nominal_handling = "regression",       # "regression" | "arbitrary_order"
  fit_data         = NULL                # data.frame com todas as colunas de variables (obrigatório em v1)
)

list_copula_families()                   # retorna famílias disponíveis na instalação
```

---

#### 4.1.5 Tipos de variável e `nominal_handling`

- **Contínua / Ordinal** — codificadas como `double` antes de construir as pseudo-observações.
- **Categórica nominal** — cópulas pressupõem ordem nas margens; `nominal_handling` controla o comportamento:
  - `"regression"` (default): erro explícito se uma nominal aparecer em `variables`.
  - `"arbitrary_order"`: inclui a nominal com a ordem de levels como declarada, emitindo `warning`.

---

#### 4.1.6 Dependência opcional

`rvinecopulib` fica em `Suggests` (não obrigatório). Sistemas que não usam `copula_mechanism()` não precisam instalá-lo. O caminho `family = "gaussian"` roda inteiramente em base R.

---

## 5. Motor de simulação (v1: DAG estático)

1. **Ordenação topológica.** Ao finalizar um `System`, computa-se uma ordem topológica das features (Kahn ou DFS). Erro explícito se houver ciclo.
2. **Geração de uma unidade.** Percorre-se a ordem topológica; para cada feature, se for raiz, amostra-se do mecanismo marginal; se tiver pais, coletam-se os valores já gerados dos pais (na mesma unidade) e aplica-se o mecanismo condicional.
3. **Geração de uma população.** Repete-se o processo de geração de unidade N vezes, com RNG controlado por seed (cada unidade pode usar um stream de RNG derivado do seed global + índice da unidade, para reprodutibilidade e para permitir comparação pareada baseline/intervenção).
4. **Aplicação de intervenção.** Dada uma lista de intervenções, constrói-se um `System` derivado (cópia com os mecanismos/arestas afetados substituídos conforme o `kind` da intervenção). Calcula-se o fecho transitivo a jusante das features-alvo (`affected_features`). Duas estratégias de regeneração, ambas suportadas:
   - **Resampling completo**: gera-se uma população nova do zero a partir do `System` derivado, usando o mesmo seed-base da baseline (unidades pareadas one-to-one).
   - **Resampling parcial (mais eficiente)**: parte-se da população baseline já gerada; mantêm-se os valores de features não afetadas; recalculam-se apenas `affected_features`, na ordem topológica, usando os valores (já fixos) dos pais não afetados e os novos valores dos pais afetados.
5. **Resultado.** Empacota-se `SimulationResult` com baseline, intervened, lista de intervenções, `affected_features` e `propagation_order`.

### 5.1 Reprodutibilidade

Toda chamada de simulação aceita um seed explícito. Dado o mesmo `System`, mesmo seed e mesmo N, a população gerada é idêntica entre execuções e (na medida do possível, respeitando diferenças de RNG entre linguagens) equivalente entre as implementações R e Python — isso deve ser validado por testes de paridade (seção 9).

---

## 6. Extensão futura: dinâmica temporal e ciclos (v2, fora do escopo de implementação imediata)

A v1 resolve sistemas estáticos. Para sistemas com feedback loops (ex.: A afeta B que afeta A de volta) ou processos que evoluem no tempo, a v2 introduz:

- **`TimeStep`**: um sistema pode ser declarado como dinâmico, no qual cada feature tem uma versão "presente" e pode depender de versões "passadas" (lagged) de si mesma ou de outras features — isso permite expressar ciclos como dependências através do tempo (A(t) depende de B(t-1), B(t) depende de A(t-1)), preservando a garantia de acausalidade dentro de um mesmo timestep.
- **Motor de simulação iterativo**: ao invés de uma única passada topológica, simula-se T passos sequenciais, cada um sendo uma passada topológica sobre o grafo "desenrolado" (unrolled) daquele timestep.
- **Intervenções dependentes do tempo**: uma intervenção pode ser aplicada a partir de um timestep específico (ex.: "a partir de t=5, fixe a feature X") e sua propagação se estende para os timesteps seguintes.
- **Compatibilidade**: um `System` v1 (estático) deve ser tratável como um caso degenerado de `System` v2 com T=1 e sem dependências defasadas — a API de v1 não deve precisar mudar quando v2 for implementada.

Esta seção é uma diretriz arquitetural, não uma especificação detalhada — será detalhada em documento próprio quando a v1 estiver estável.

---

## 7. Arquitetura de software

Camadas, da mais baixa para a mais alta:

1. **Type system** — `FeatureType`, validação de domínio, codificação/decodificação de valores (ex.: categórica como string vs. código interno).
2. **Graph engine** — representação do grafo de dependência, checagem de aciclicidade, ordenação topológica, cálculo de fecho transitivo (ancestrais/descendentes de um nó) — usado tanto para validação quanto para identificar `affected_features` em intervenções.
3. **Mechanism library** — mecanismos pré-fabricados por combinação de tipos (seção 4), o mecanismo de cópula via `vinecopulib` (seção 4.1), e o registro de mecanismos customizados.
4. **System builder** — API para declarar features, arestas e mecanismos, e para validar/"finalizar" um `System` (rodar os invariantes da seção 3.5).
5. **Simulation engine** — geração de unidades/populações dado um `System` finalizado e um seed (seção 5).
6. **Intervention engine** — construção de `System` derivado a partir de intervenções, cálculo de `affected_features`, execução do resampling completo ou parcial.
7. **I/O / serialização** — exportar/importar um `System` (sem dados simulados) em um formato textual (JSON ou YAML) comum às duas linguagens, para que um sistema definido em Python possa, em tese, ser carregado em R (e vice-versa). Esse formato serializado é o contrato de paridade entre as duas implementações.
8. **(Futuro) Domain extension layer** — não faz parte do core; é o espaço onde soluções específicas de domínio (epidemiologia, mercado, etc.) usam o `lepidoptera` como dependência.

---

## 8. API pública (espelhada R / Python)

Convenção: nomes de função em `snake_case` em ambas as linguagens. Em Python, entidades como `System`, `FeatureSpec`, `Mechanism`, `Intervention` são classes. Em R, são objetos S3 (ou R6, a decidir na implementação) com construtores `new_*()` e métodos via funções genéricas — a tabela abaixo lista a função/método equivalente em cada lado, não a classe interna.

| Operação | Python | R |
|---|---|---|
| Criar especificação de feature | `feature_spec(name, type, domain, metadata=None)` | `feature_spec(name, type, domain, metadata = NULL)` |
| Criar sistema vazio | `System()` | `new_system()` |
| Adicionar feature | `system.add_feature(spec)` | `add_feature(system, spec)` |
| Adicionar dependência + mecanismo | `system.add_dependency(parents, child, mechanism)` | `add_dependency(system, parents, child, mechanism)` |
| Registrar mecanismo customizado | `register_mechanism(name, fn, parent_types, output_type)` | `register_mechanism(name, fn, parent_types, output_type)` |
| Buscar mecanismo pré-fabricado | `mechanism_library.get(key)` | `mechanism_library_get(key)` |
| Mecanismo de cópula (vine) | `copula_mechanism(variables, family="auto", marginals="auto", nominal_handling="regression", fit_data=None)` | `copula_mechanism(variables, family = "auto", marginals = "auto", nominal_handling = "regression", fit_data = NULL)` |
| Finalizar/validar sistema | `system.finalize()` | `finalize_system(system)` |
| Simular população | `simulate(system, n, seed=None)` | `simulate(system, n, seed = NULL)` |
| Criar intervenção (fix) | `do_fix(target, value)` | `do_fix(target, value)` |
| Criar intervenção (distribuição) | `do_distribution(target, distribution)` | `do_distribution(target, distribution)` |
| Criar intervenção (shift) | `shift(target, fn)` | `shift(target, fn)` |
| Criar intervenção (override de mecanismo) | `mechanism_override(target, mechanism)` | `mechanism_override(target, mechanism)` |
| Aplicar intervenção(ões) e propagar | `propagate(system, interventions, n=None, seed=None, mode="full"/"partial")` | `propagate(system, interventions, n = NULL, seed = NULL, mode = "full")` |
| Comparar resultados | `compare(result)` (método de `SimulationResult`) | `compare(result)` |
| Exportar sistema | `system.to_json(path)` / `system.to_yaml(path)` | `export_system(system, path, format = "json")` |
| Importar sistema | `System.from_json(path)` | `import_system(path, format = "json")` |
| Visualizar grafo | `system.plot_graph()` | `plot_graph(system)` |

Notas de paridade:
- Toda função que aceita `seed` deve, dado o mesmo `System` serializado e o mesmo `seed`, produzir populações estatisticamente equivalentes (não necessariamente bit-idênticas, dado que os RNGs de R e Python diferem internamente — mas a especificação de distribuições e parâmetros deve ser idêntica). Bit-identidade exata entre linguagens não é objetivo; equivalência distribucional é.
- Mensagens de erro de validação (sistema com ciclo, mecanismo com tipo incompatível, etc.) devem expressar a mesma informação estruturada nas duas linguagens (mesmo "código" de erro), ainda que o texto varie.

---

## 9. Estratégia de testes e validação de paridade

- **Testes unitários por camada**, replicados em R e Python: type system, graph engine (aciclicidade, ordenação topológica, fecho transitivo), mecanismos pré-fabricados (cada combinação de tipos da seção 4), invariantes do `System`.
- **Testes de paridade cross-language**: um conjunto de sistemas de referência, serializados em JSON, é carregado tanto em R quanto em Python; a simulação com o mesmo seed (ou um número grande de unidades, comparando momentos/distribuições agregadas) deve produzir resultados estatisticamente equivalentes dentro de uma tolerância definida.
- **Testes de intervenção**: para cada sistema de referência, aplicar intervenções conhecidas e verificar que `affected_features` corresponde exatamente ao fecho transitivo esperado, e que features fora desse fecho permanecem idênticas entre baseline e intervened (no modo "partial").

---

## 10. Roadmap

- **v0.1 (este documento)** — especificação congelada para implementação inicial.
- **v1.0** — DAG estático, tipos mistos completos (seção 4), motor de propagação one-shot, API espelhada R/Python, serialização JSON, testes de paridade.
- **v1.x** — biblioteca de mecanismos expandida, visualização de grafo, melhorias de performance (vetorização da geração de população).
- **v2.0** — dinâmica temporal e ciclos via dependências defasadas (seção 6), mantendo compatibilidade retroativa com sistemas v1.
- **v2.x+** — ponto de partida para soluções de domínio específico construídas sobre `lepidoptera` (camada de extensão, seção 7.8).
- **v1.x+ (transversal)** — camada de integração com IA (seção 12), incremental e opcional, não bloqueia v1.0/v2.0.

---

## 11. Integração com IA (LLMs/transformers) — extensão opcional e transversal

`lepidoptera` é desenhado para nascer "AI-native" sem precisar mudar a arquitetura central: a regra de que **qualquer função que respeite a assinatura de `Mechanism` é válida** (seção 3.3/4) já é a porta de entrada — um mecanismo cuja `fn` chama um LLM, ou um modelo treinado (incluindo arquiteturas transformer), é só mais um `Mechanism`. As frentes abaixo são extensões opcionais, ortogonais ao motor de propagação (seções 5-6) e independentes entre si — podem ser adotadas uma por vez, em qualquer ordem, sem alterar o core.

### 11.1 `llm_mechanism` — mecanismo gerador via LLM

Um mecanismo cuja função geradora é uma chamada a um LLM, útil sobretudo para features semânticas/textuais que não cabem bem em regressão (seção 4) nem em cópula (seção 4.1) — ex.: dado idade, renda e histórico de um cliente (pais), gerar a categoria de sentimento ou um trecho de texto descritivo (filho).

Assinatura conceitual (espelhada R/Python, mesmo padrão da seção 8):

```
llm_mechanism(
  prompt_template,   # template com placeholders para os valores dos pais
  model,             # identificador do modelo/provedor
  parents,           # nomes dos pais, na ordem em que preenchem o template
  output_type,       # FeatureType do valor retornado
  parser = "auto"    # como o texto de saída do LLM é convertido para output_type
                      # (ex.: mapeamento para nível categórico/ordinal, parsing numérico para contínua)
)
```

`output_type`/`parent_types` são inferidos como em qualquer outro `Mechanism` (seção 3.3) — para o `System`, um nó com `llm_mechanism` é indistinguível de um nó com mecanismo de regressão ou de cópula.

**Custo e determinismo.** Chamadas a LLM têm custo e latência por unidade simulada, e não são deterministas mesmo com seed fixo (a menos que o backend ofereça controle de temperatura/seed) — `finalize_system()` emite aviso quando um `llm_mechanism` está em um caminho que será executado N vezes por unidade simulada, sugerindo cache por combinação de valores de pais (memoização) quando o domínio dos pais é finito (categórico/ordinal) ou discretizável.

### 11.2 `learned_mechanism` — mecanismo ajustado a dados (qualquer modelo, incluindo transformers tabulares)

Generalização do padrão já usado em `copula_mechanism` (`fit_data`, seção 4.1): em vez de um modelo de cópula, qualquer modelo preditivo ajustável a dados observados — incluindo modelos transformer para dados tabulares — vira o mecanismo de um nó.

```
learned_mechanism(
  parents, child,
  model = "auto",     # "auto" | "gbm" | "transformer" | objeto de modelo já ajustado
  fit_data,           # dados observados de parents + child
  uncertainty = "auto" # como a incerteza do modelo é propagada na amostragem (ex.: resíduos, distribuição preditiva)
)
```

Caso de uso típico: "tenho uma amostra observada dessas variáveis, quero que o mecanismo aprenda a relação automaticamente em vez de eu especificar a forma funcional" — mesmo espírito do `fit_data` da seção 4.1, mas sem exigir estrutura de cópula.

### 11.3 `model_mechanism` — usar um modelo pré-treinado externo como mecanismo

Difere do `learned_mechanism` em um ponto fundamental: `learned_mechanism` **treina** um modelo internamente a partir de `fit_data`; `model_mechanism` **usa** um modelo que o usuário já treinou fora do `lepidoptera` (um `ranger` random forest, um `glm`, um `xgboost`, um modelo `keras`, etc.).

```r
model_mechanism(
  predict_fn,          # function(parent_values) -> single value
  parents,             # character vector: parent feature names
  parent_types,        # character vector: feature_types() entry per parent
  output_type,         # one of feature_types()
  levels   = NULL,     # required if output_type is "categorical" or "ordinal"
  name     = "model_mechanism"
)
```

O usuário é responsável pelo `predict_fn` completo: receber `parent_values` (named list), chamar o modelo, extrair o slot de saída correto, e opcionalmente adicionar ruído estocástico (ex.: resíduos Gaussianos para um `lm`). Para o `System`, um nó com `model_mechanism` é indistinguível de qualquer outro `Mechanism`.

**Casos de uso típicos.** (a) usar um random forest treinado em dados observacionais como mecanismo gerador de uma feature; (b) usar um modelo de regressão logística para gerar desfechos categóricos; (c) integrar modelos de deep learning (via qualquer wrapper R) ao sistema de simulação sem necessidade de API específica — o `predict_fn` é a fronteira de integração.

### 11.4 Geração de `System` a partir de linguagem natural

Um LLM traduz uma descrição em texto livre do domínio ("um sistema com tabagismo, renda e doença cardíaca, em que renda afeta tabagismo e ambos afetam doença cardíaca") diretamente para o formato de serialização da seção 7, camada 7 (JSON/YAML) — o mesmo contrato já usado para paridade R/Python (`export_system`/`import_system`). Isso significa que essa frente **não exige nenhuma API nova**: o LLM só precisa aprender a gerar um artefato que o core já sabe importar e validar via `finalize_system()`/`System.finalize()`. Erros de validação (seção 3.5) funcionam como sinal de retroalimentação para o LLM corrigir a especificação gerada.

### 11.4 Consulta de intervenção em linguagem natural

Um LLM traduz uma pergunta em texto livre ("o que acontece com a doença cardíaca se eu aumentar a renda em 10%?") para uma chamada de `propagate()` com as `Intervention` correspondentes (`do_fix`/`do_distribution`/`shift`/`mechanism_override`, seção 3.6), executa a simulação, e narra o `SimulationResult`/`compare()` de volta em texto. Combina-se naturalmente com 11.3: descrever o sistema e perguntar sobre intervenções na mesma conversa.

### 11.5 Camada de ferramentas para agentes (MCP/tool-calling)

Expor a API pública da seção 8 (`add_feature`, `add_dependency`, `simulate`, `propagate`, etc.) como ferramentas chamáveis por um agente de LLM (ex.: via protocolo MCP) — o agente manipula um `System` passo a passo, decide quando simular e quando intervir, e relata resultados. Esta frente depende apenas da API pública já especificada; não requer nenhuma mudança no core além de um wrapper fino por cima de cada função/método.

### 11.6 Metadados semânticos

O campo `metadata` de `FeatureSpec` (seção 3.2), já presente e nunca interpretado pelo core, é o espaço natural para guardar descrições semânticas, embeddings ou anotações geradas por LLM — permitindo busca/similaridade entre features e mecanismos de sistemas diferentes (ex.: "encontre um sistema parecido com este já especificado"), sem exigir nenhum campo novo na estrutura de dados.

### 11.7 Ordem de implementação recomendada

Não há dependência técnica forte entre 11.1-11.6, mas a ordem de maior retorno é: (1) `llm_mechanism`/`learned_mechanism` — cabe na arquitetura atual sem mudar o spec; (2) geração de `System` via linguagem natural — abre a porta de entrada para usuários não-técnicos; (3) consulta de intervenção em linguagem natural — fecha o loop de "conversar com a simulação"; (4) camada de agente/MCP — depende de o core (seções 3-5) já estar minimamente implementado, já que expõe a API real, não um placeholder.

---

## 12. Glossário rápido

- **DAG**: grafo acíclico dirigido.
- **Mecanismo marginal**: gera valor sem depender de outras features (feature-raiz).
- **Mecanismo condicional**: gera valor a partir dos valores dos pais.
- **Fecho transitivo a jusante**: todas as features alcançáveis a partir de um nó seguindo as arestas na direção da dependência (descendentes).
- **Resampling parcial**: recalcular só as features afetadas por uma intervenção, mantendo o resto da população intacto.
- **Paridade R/Python**: garantia de que as duas implementações representam o mesmo modelo conceitual e produzem resultados equivalentes a partir da mesma especificação de sistema.
- **Mecanismo via LLM/aprendido/externo**: mecanismo cuja função geradora é uma chamada a um LLM, um modelo ajustado a dados internamente, ou um modelo pré-treinado externo (seções 11.1-11.3), tratado pelo core como qualquer outro `Mechanism`.
