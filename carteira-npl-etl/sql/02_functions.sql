/* =====================================================================
   02_functions.sql

   O QUE ESTE SCRIPT FAZ
   Cria as funcoes de limpeza, validacao e conversao usadas pela
   validacao e pela carga.

   PRINCIPIO QUE VALE PARA TODAS ELAS
   Nenhuma funcao aqui pode estourar erro. Arquivo externo sempre chega
   sujo, entao a funcao precisa devolver NULL ou 0 diante de lixo, nunca
   abortar. Se uma funcao de conversao falhar com excecao, ela derruba a
   procedure inteira e o arquivo todo para por causa de uma linha, que e
   exatamente o comportamento que o projeto existe para evitar.

   LIMITACAO CONHECIDA, E VALE SABER EXPLICAR
   Sao funcoes escalares (scalar UDF). Usadas em predicado de WHERE, elas
   limitam paralelismo e sao avaliadas linha a linha. No SQL Server 2019
   em diante existe o scalar UDF inlining, que ajuda bastante, mas a
   versao realmente escalavel seria materializar as colunas convertidas
   numa unica passada, ou usar funcao inline com valor de tabela (iTVF).
   Para o volume deste lab o custo e irrelevante. Para milhoes de linhas,
   nao seria.
   ===================================================================== */

USE CarteiraNPL;
GO

/* ---------------------------------------------------------------------
   util.fn_somente_digitos

   O QUE FAZ
   Remove tudo que nao for digito. Serve para normalizar CPF, CNPJ e
   telefone, que chegam ora com mascara, ora sem.

   POR QUE UM LOOP COM PATINDEX
   PATINDEX('%[^0-9]%') acha a posicao do primeiro caractere que nao e
   numero e STUFF remove aquele caractere. O loop repete ate sobrar so
   digito. E generico: funciona para ponto, traco, barra, espaco,
   parentese ou qualquer sujeira que apareca, sem precisar prever cada
   caractere.

   ALTERNATIVA DESCARTADA
   REPLACE aninhado, tipo REPLACE(REPLACE(x,'.',''),'-',''). E mais
   rapido, mas so remove o que voce lembrou de listar. O primeiro cedente
   que mandar CPF com espaco no meio passa despercebido.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_somente_digitos (@texto VARCHAR(200))
RETURNS VARCHAR(200)
AS
BEGIN
    DECLARE @saida VARCHAR(200) = ISNULL(@texto, '');
    DECLARE @pos INT = PATINDEX('%[^0-9]%', @saida);

    WHILE @pos > 0
    BEGIN
        SET @saida = STUFF(@saida, @pos, 1, '');
        SET @pos = PATINDEX('%[^0-9]%', @saida);
    END

    RETURN @saida;
END
GO

/* ---------------------------------------------------------------------
   util.fn_valida_cpf

   O QUE FAZ
   Valida CPF pelo algoritmo dos dois digitos verificadores.

   COMO O ALGORITMO FUNCIONA
   Primeiro digito: multiplica os 9 primeiros numeros por pesos que vao
   de 10 ate 2, soma tudo, e o digito e 11 menos o resto da divisao por
   11. Se der 10 ou mais, o digito e 0.
   Segundo digito: mesma coisa com os 10 primeiros numeros e pesos de 11
   ate 2.

   POR QUE A LINHA DA SEQUENCIA REPETIDA
   CPFs como 11111111111 passam no calculo matematico mas nao existem.
   Sem essa checagem, um arquivo preenchido com valor padrao seria aceito
   como documento valido, que e um erro de dado silencioso e caro.

   POR QUE VALIDAR NO BANCO E NAO CONFIAR NO CEDENTE
   Porque o dado chega de fora. Documento invalido significa que aquele
   contrato nao pode ser cobrado nem localizado, entao e melhor descobrir
   na entrada do que na hora do acionamento.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_valida_cpf (@documento VARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @cpf VARCHAR(20) = util.fn_somente_digitos(@documento);
    DECLARE @i INT, @soma INT, @dv1 INT, @dv2 INT;

    IF LEN(@cpf) <> 11 RETURN 0;

    IF @cpf = REPLICATE(LEFT(@cpf, 1), 11) RETURN 0;

    SET @soma = 0;
    SET @i = 1;
    WHILE @i <= 9
    BEGIN
        SET @soma = @soma + CAST(SUBSTRING(@cpf, @i, 1) AS INT) * (11 - @i);
        SET @i = @i + 1;
    END
    SET @dv1 = 11 - (@soma % 11);
    IF @dv1 >= 10 SET @dv1 = 0;
    IF @dv1 <> CAST(SUBSTRING(@cpf, 10, 1) AS INT) RETURN 0;

    SET @soma = 0;
    SET @i = 1;
    WHILE @i <= 10
    BEGIN
        SET @soma = @soma + CAST(SUBSTRING(@cpf, @i, 1) AS INT) * (12 - @i);
        SET @i = @i + 1;
    END
    SET @dv2 = 11 - (@soma % 11);
    IF @dv2 >= 10 SET @dv2 = 0;
    IF @dv2 <> CAST(SUBSTRING(@cpf, 11, 1) AS INT) RETURN 0;

    RETURN 1;
END
GO

/* ---------------------------------------------------------------------
   util.fn_valida_cnpj

   Mesma logica do CPF, com 14 digitos e pesos diferentes.

   POR QUE OS PESOS ESTAO NUMA STRING
   T-SQL nao tem array. Guardar os pesos em '543298765432' e ler com
   SUBSTRING e a forma mais legivel de percorrer a sequencia sem escrever
   doze multiplicacoes na mao. Evita erro de digitacao e deixa claro qual
   e a sequencia de pesos da regra.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_valida_cnpj (@documento VARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @cnpj VARCHAR(20) = util.fn_somente_digitos(@documento);
    DECLARE @pesos1 CHAR(12) = '543298765432';
    DECLARE @pesos2 CHAR(13) = '6543298765432';
    DECLARE @i INT, @soma INT, @dv1 INT, @dv2 INT;

    IF LEN(@cnpj) <> 14 RETURN 0;
    IF @cnpj = REPLICATE(LEFT(@cnpj, 1), 14) RETURN 0;

    SET @soma = 0;
    SET @i = 1;
    WHILE @i <= 12
    BEGIN
        SET @soma = @soma + CAST(SUBSTRING(@cnpj, @i, 1) AS INT)
                          * CAST(SUBSTRING(@pesos1, @i, 1) AS INT);
        SET @i = @i + 1;
    END
    SET @dv1 = 11 - (@soma % 11);
    IF @dv1 >= 10 SET @dv1 = 0;
    IF @dv1 <> CAST(SUBSTRING(@cnpj, 13, 1) AS INT) RETURN 0;

    SET @soma = 0;
    SET @i = 1;
    WHILE @i <= 13
    BEGIN
        SET @soma = @soma + CAST(SUBSTRING(@cnpj, @i, 1) AS INT)
                          * CAST(SUBSTRING(@pesos2, @i, 1) AS INT);
        SET @i = @i + 1;
    END
    SET @dv2 = 11 - (@soma % 11);
    IF @dv2 >= 10 SET @dv2 = 0;
    IF @dv2 <> CAST(SUBSTRING(@cnpj, 14, 1) AS INT) RETURN 0;

    RETURN 1;
END
GO

/* ---------------------------------------------------------------------
   util.fn_valida_documento e util.fn_tipo_pessoa

   O QUE FAZEM
   Decidem entre pessoa fisica e juridica pelo tamanho do documento e
   despacham para a validacao correta.

   POR QUE ASSIM
   A carteira mistura PF e PJ no mesmo arquivo. Uma unica funcao de
   entrada evita que a procedure de validacao precise saber dessa regra,
   e concentra num lugar so a decisao de o que e 11 e o que e 14 digitos.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_valida_documento (@documento VARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @doc VARCHAR(20) = util.fn_somente_digitos(@documento);

    IF LEN(@doc) = 11 RETURN util.fn_valida_cpf(@doc);
    IF LEN(@doc) = 14 RETURN util.fn_valida_cnpj(@doc);

    RETURN 0;
END
GO

CREATE OR ALTER FUNCTION util.fn_tipo_pessoa (@documento VARCHAR(50))
RETURNS CHAR(1)
AS
BEGIN
    DECLARE @doc VARCHAR(20) = util.fn_somente_digitos(@documento);
    RETURN CASE WHEN LEN(@doc) = 14 THEN 'J' ELSE 'F' END;
END
GO

/* ---------------------------------------------------------------------
   util.fn_converte_data

   O QUE FAZ
   Tenta converter texto em data aceitando os formatos que os cedentes
   costumam mandar, e devolve NULL quando nao consegue.

   POR QUE TRY_CONVERT E NAO CONVERT
   CONVERT lanca excecao diante de texto invalido e aborta o lote inteiro.
   TRY_CONVERT devolve NULL, que e exatamente o sinal que a validacao
   precisa para mandar a linha para a quarentena.

   POR QUE O COALESCE COM TRES ESTILOS
   103 cobre dd/MM/yyyy e dd-MM-yyyy, 112 cobre yyyyMMdd e 23 cobre
   yyyy-MM-dd. Sao os tres padroes que aparecem em arquivo de carteira.
   A ordem importa: 103 vem primeiro porque o padrao brasileiro e o mais
   frequente, entao a maioria das linhas resolve na primeira tentativa.

   ARMADILHA QUE ESSA FUNCAO EVITA
   Sem estilo explicito, "03/04/2024" seria interpretado como marco ou
   abril dependendo do idioma da sessao. Dois servidores com configuracao
   diferente produziriam resultados diferentes para o mesmo arquivo.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_converte_data (@texto VARCHAR(30))
RETURNS DATE
AS
BEGIN
    DECLARE @t VARCHAR(30) = LTRIM(RTRIM(ISNULL(@texto, '')));

    IF @t = '' RETURN NULL;

    RETURN COALESCE(
        TRY_CONVERT(DATE, @t, 103),   -- dd/MM/yyyy e dd-MM-yyyy
        TRY_CONVERT(DATE, @t, 112),   -- yyyyMMdd
        TRY_CONVERT(DATE, @t, 23)     -- yyyy-MM-dd
    );
END
GO

/* ---------------------------------------------------------------------
   util.fn_converte_decimal

   O QUE FAZ
   Converte valor monetario aceitando tanto 1.234,56 quanto 1234.56.

   COMO DECIDE QUAL E O SEPARADOR DECIMAL
   Se existe virgula no texto, entao a virgula e o separador decimal e o
   ponto so pode ser separador de milhar. Nesse caso remove os pontos e
   troca a virgula por ponto. Se nao tem virgula, o texto ja esta no
   formato que o SQL Server entende e passa direto.

   POR QUE ISSO IMPORTA
   Sem essa regra, "1.234,56" convertido as cegas viraria 1.234 ou daria
   erro, e um saldo de mil e duzentos reais viraria um real e vinte.
   Erro de escala em carteira de credito e o tipo de defeito que so
   aparece no fechamento contabil.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_converte_decimal (@texto VARCHAR(40))
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @t VARCHAR(40) = REPLACE(LTRIM(RTRIM(ISNULL(@texto, ''))), ' ', '');

    IF @t = '' RETURN NULL;

    SET @t = REPLACE(REPLACE(@t, 'R$', ''), CHAR(9), '');

    IF CHARINDEX(',', @t) > 0
        SET @t = REPLACE(REPLACE(@t, '.', ''), ',', '.');

    RETURN TRY_CONVERT(DECIMAL(18,2), @t);
END
GO

/* ---------------------------------------------------------------------
   util.fn_normaliza_nome

   O QUE FAZ
   Tira espacos das pontas, colapsa espacos duplicados e padroniza em
   caixa alta.

   POR QUE PADRONIZAR
   "Ana  Silva", "ANA SILVA " e "ana silva" sao a mesma pessoa. Sem
   normalizar, a comparacao usada pelo MERGE acusaria mudanca a cada
   carga e gravaria um UPDATE desnecessario todo dia, inchando o log de
   transacao sem nenhuma alteracao real de dado.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION util.fn_normaliza_nome (@texto VARCHAR(200))
RETURNS VARCHAR(150)
AS
BEGIN
    DECLARE @t VARCHAR(200) = UPPER(LTRIM(RTRIM(ISNULL(@texto, ''))));

    WHILE CHARINDEX('  ', @t) > 0
        SET @t = REPLACE(@t, '  ', ' ');

    RETURN LEFT(@t, 150);
END
GO

PRINT 'Funcoes criadas com sucesso.';
GO
