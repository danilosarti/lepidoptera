# lepidoptera (Python)

Implementação Python do `lepidoptera`, em paralelo com a versão R na raiz
do repositório. Especificação completa do design (modelo de dados,
combinações de tipos, mecanismo de cópula via `vinecopulib`, motor de
propagação, arquitetura e API espelhada R/Python): ver
[`../SPEC.md`](../SPEC.md).

Status: esqueleto do pacote — funções e classes declaradas e documentadas,
ainda sem implementação (`raise NotImplementedError(...)` em cada uma).

## Instalação (modo desenvolvimento)

```bash
pip install -e ".[copula,graph,plot,test]"
```

`pyvinecopulib` (extra `copula`) é opcional: só é necessário para usar
`copula_mechanism()` (SPEC.md seção 4.1).

## Estrutura

- `src/lepidoptera/type_system.py` — tipos de feature e validação de domínio
- `src/lepidoptera/graph.py` — grafo de dependência, ordenação topológica, fecho transitivo
- `src/lepidoptera/mechanism.py` — biblioteca de mecanismos e registro de customizados
- `src/lepidoptera/copula.py` — mecanismo de cópula (vine copulas via `pyvinecopulib`)
- `src/lepidoptera/system.py` — construção e validação de um `System`
- `src/lepidoptera/simulate.py` — geração de população a partir de um `System`
- `src/lepidoptera/intervention.py` — intervenções e propagação de efeitos
- `src/lepidoptera/io.py` — serialização (contrato de paridade com a versão R)
- `src/lepidoptera/plot.py` — visualização do grafo (utilitário secundário)

## Testes

```bash
pytest
```
