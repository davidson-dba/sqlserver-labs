# SSIS passo a passo

Instruções para montar os dois packages do zero. Escrito assumindo Visual Studio 2022 com a extensão **SQL Server Integration Services Projects**.

## Conceitos em 30 segundos

| Conceito | O que é |
|---|---|
| **Control Flow** | A sequência de tarefas do package. É a receita. |
| **Data Flow** | Uma tarefa especial que move linhas de A para B. É o cano. |
| **Connection Manager** | Ponteiro para um arquivo ou banco. Fica fora do package quando definido no nível de projeto. |
| **Variable / Parameter** | Variável vive dentro do package, parâmetro é exposto na execução. |
| **Precedence Constraint** | A seta entre tarefas. Pode ser Success, Failure, Completion, ou uma expressão. |

Erro clássico de iniciante: tentar fazer validação dentro do Data Flow. Não faça. O Data Flow só empurra o arquivo bruto para o staging. Toda regra de negócio fica em T-SQL, onde é testável, versionável e não depende de abrir o Visual Studio para entender.

---

## Criar o projeto

1. Visual Studio → Create a new project → **Integration Services Project**
2. Nome: `CarteiraNPL`
3. Em **Solution Explorer**, clique com o botão direito em **Connection Managers** → New Connection Manager. Criar no nível de projeto (compartilhado entre packages):
   - `CM_SQL` do tipo **OLEDB**, apontando para a instância e o banco `CarteiraNPL`
   - `CM_CONTRATOS` do tipo **FLATFILE**
   - `CM_PARCELAS` do tipo **FLATFILE**

### Configurando o Flat File Connection Manager

Na aba **General**:
- File name: aponte para um CSV de exemplo gerado
- Format: **Delimited**
- Text qualifier: `<none>`
- Header row delimiter: `{LF}` (o gerador grava com quebra Unix)
- **Marque** "Column names in the first data row"
- Code page: **65001 (UTF-8)**

Na aba **Advanced**, para **cada coluna**:
- DataType: `string [DT_STR]`
- OutputColumnWidth: **100**

Isso não é preguiça, é intencional. O staging é texto puro. Se você deixar o SSIS inferir tipos, o primeiro arquivo com data ruim derruba o package inteiro, que é exatamente o que queremos evitar.

Na aba **Preview**, confira se as colunas estão alinhadas antes de sair.

---

## PKG_01_IMPORT_CARTEIRA.dtsx

Renomeie o `Package.dtsx` padrão.

### Variáveis

Menu SSIS → Variables:

| Nome | Tipo | Valor |
|---|---|---|
| `IdLote` | Int32 | 0 |
| `NomeArquivo` | String | `CONTRATOS_237_20260911.csv` |
| `CodCedente` | String | `237` |
| `PastaEntrada` | String | `C:\carteira-npl-etl\arquivos\entrada\` |
| `PastaProcessados` | String | `C:\carteira-npl-etl\arquivos\processados\` |

### Tarefa 1 — Execute SQL Task "SQL Abrir Lote"

- Connection: `CM_SQL`
- SQLSourceType: Direct input
- SQLStatement: `EXEC ctl.sp_abrir_lote ?, ?, NULL, 0`
- **ResultSet: Single row**
- Aba **Parameter Mapping**:

| Variable | Direction | Data Type | Parameter Name |
|---|---|---|---|
| `User::NomeArquivo` | Input | VARCHAR | 0 |
| `User::CodCedente` | Input | VARCHAR | 1 |

- Aba **Result Set**: Result Name `0` → Variable Name `User::IdLote`

Se a procedure barrar por arquivo já carregado, a tarefa falha aqui e o package para antes de sujar o staging. É o comportamento desejado.

### Tarefa 2 — Data Flow Task "DFT Staging Contratos"

Dentro do Data Flow:

1. **Flat File Source** → connection `CM_CONTRATOS`
2. **Derived Column** → nova coluna `id_lote`, Data Type `four-byte signed integer [DT_I4]`, Expression: `@[User::IdLote]`
3. **OLE DB Destination**
   - Connection: `CM_SQL`
   - Data access mode: **Table or view - fast load**
   - Table: `[stg].[contrato_carteira]`
   - Rows per batch: `10000`
   - Maximum insert commit size: `10000`
   - Aba **Mappings**: mapeie coluna a coluna. `id_stg`, `fl_valido` e `dt_carga` ficam **sem mapeamento** (identity e defaults).

Na aba **Error Output** do destino, mude para **Redirect row** e ligue num **Flat File Destination** apontando para `arquivos\saida\rejeitados_carga.csv`. Linha que nem no staging entra precisa ir para algum lugar.

### Tarefa 3 — Data Flow Task "DFT Staging Parcelas"

Mesma coisa com `CM_PARCELAS` e `[stg].[parcela_contrato]`.

### Tarefa 4 — Execute SQL Task "SQL Validar"

- SQLStatement: `EXEC stg.sp_validar_lote ?`
- Parameter Mapping: `User::IdLote`, Input, LONG, parâmetro `0`

### Tarefa 5 — Execute SQL Task "SQL Carregar"

- SQLStatement: `EXEC crd.sp_carregar_lote ?`
- Mesmo mapeamento do `IdLote`

### Tarefa 6 — File System Task "FS Mover Arquivo"

- Operation: **Move file**
- Source e Destination via Connection Manager de arquivo, ou use expressões com `@[User::PastaEntrada] + @[User::NomeArquivo]`

### Ligações

Ligue as tarefas na ordem 1 → 2 → 3 → 4 → 5 → 6 com setas verdes (Success).

### Tratamento de erro

Aba **Event Handlers**, Executable: o package, Event handler: **OnError**. Adicione um Execute SQL Task:

```sql
EXEC ctl.sp_registrar_log ?, 'ERRO_SSIS', ?
```

Mapeando `User::IdLote` e `System::ErrorDescription`.

---

## PKG_02_EXPORT_RETORNO.dtsx

Mais simples, só um Data Flow:

1. **OLE DB Source**
   - Data access mode: **SQL command**
   - SQL: `EXEC exp.sp_gerar_retorno ?`
   - Botão **Parameters** → mapeie `User::IdLote`
   - Se o SSIS reclamar que não consegue ler os metadados da procedure, acrescente `SET FMTONLY OFF;` antes do EXEC, ou troque por um `SELECT` direto da view `exp.vw_retorno_lote` com filtro por lote. A segunda opção é mais estável.
2. **Flat File Destination**
   - Nova connection delimitada por `;`, UTF-8
   - Arquivo: `arquivos\saida\RETORNO_237_<data>.csv`
   - Marque "Overwrite data in the file"

Para o nome do arquivo ficar dinâmico, selecione o Flat File Connection Manager, painel **Properties**, **Expressions**, propriedade `ConnectionString`:

```
@[User::PastaSaida] + "RETORNO_" + @[User::CodCedente] + "_" +
(DT_WSTR,4) YEAR(GETDATE()) +
RIGHT("0" + (DT_WSTR,2) MONTH(GETDATE()), 2) +
RIGHT("0" + (DT_WSTR,2) DAY(GETDATE()), 2) + ".csv"
```

---

## Armadilhas que vão te custar tempo

- **Validação atrasada**: se o arquivo não existe no caminho configurado, o package acusa erro antes de rodar. Em Properties do package ou da tarefa, `DelayValidation = True` resolve.
- **Runtime 32 vs 64 bits**: em Project Properties → Debugging, `Run64BitRuntime`. Provedores de Excel e Access antigos só existem em 32 bits.
- **Coluna truncada**: erro `DTS_E_INDUCEDTRANSFORMFAILUREONERROR` quase sempre é largura de coluna no Flat File Connection Manager. Aumente para 100 e siga.
- **Acentuação virando `?`**: code page diferente de 65001 no Flat File. Se usar `DT_WSTR` em vez de `DT_STR`, o destino precisa de colunas `NVARCHAR`.
- **Quebra de linha**: o gerador Python grava com `\n`. Se abrir e salvar no Bloco de Notas do Windows, vira `\r\n` e o SSIS reclama. Confira o Row delimiter.
- **`EXEC` em OLE DB Source**: use a view, é menos briga.

---

## Bônus, se sobrar tempo

**Foreach Loop Container** varrendo `*.csv` da pasta de entrada, com a variável `NomeArquivo` recebendo o nome de cada arquivo a cada iteração. Envolve as tarefas 1 a 6 dentro do loop. É assim que a coisa funciona na vida real: ninguém roda package arquivo por arquivo.

Configuração: Collection → Foreach File Enumerator, Folder = `@[User::PastaEntrada]`, Files = `CONTRATOS_*.csv`, Retrieve file name = **Name and extension**. Em Variable Mappings, `User::NomeArquivo` índice 0.
