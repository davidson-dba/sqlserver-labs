#!/usr/bin/env python3
"""
Gerador de arquivos de carteira de credito inadimplente.

O QUE ESTE SCRIPT FAZ
Produz dois CSV delimitados por ponto e virgula, no formato que um
cedente mandaria:
  CONTRATOS_<cedente>_<data>.csv
  PARCELAS_<cedente>_<data>.csv

POR QUE GERAR DADO SINTETICO EM VEZ DE USAR UM ARQUIVO REAL
Duas razoes. A obvia: dado real de carteira e dado pessoal, nao pode ir
para um repositorio publico. A menos obvia e mais importante: dado real
nao permite controlar quais defeitos existem. Aqui eu decido que 10% das
linhas tem problema e exatamente quais problemas sao, entao consigo
provar que cada regra de validacao esta pegando o que deveria pegar. Um
lab sem dado ruim controlado nao testa nada.

O DESENHO DOS DEFEITOS
Cada defeito injetado corresponde a uma regra do pipeline:
  cpf        -> E001, digito verificador errado
  nome       -> E002, campo vazio ou com uma letra so
  data       -> E003, texto que nao converte para data
  futuro     -> E004, contratacao com data futura
  principal  -> E005, valor zerado
  atualizado -> E006, atualizado menor que o principal (gera alerta)
  atraso     -> E007, dias de atraso negativo
  uf         -> E008, sigla inexistente
  produto    -> E009, produto fora do catalogo
Alem disso, no final sao inseridos contratos repetidos (E010) e parcelas
apontando para contrato inexistente (E020).

POR QUE DATA E VALOR SAEM EM FORMATOS ALTERNADOS
As funcoes data_br e valor_br sorteiam entre dd/MM/yyyy e yyyy-MM-dd, e
entre 1234.56 e 1.234,56. Isso nao e defeito, e realidade: cedentes
diferentes mandam em padroes diferentes, e as vezes o mesmo cedente muda
de padrao entre um sistema e outro. O pipeline precisa aguentar os dois,
e e por isso que as funcoes de conversao do script 02 existem.
O CPF tambem sai ora mascarado, ora limpo, pelo mesmo motivo. E isso que
torna a normalizacao do documento obrigatoria antes do MERGE.

POR QUE SO BIBLIOTECA PADRAO
Nada de pandas ou faker. O script vai rodar numa VM onde talvez nao haja
internet liberada para pip. Dependencia zero significa que ele roda em
qualquer lugar com Python instalado.

USO
    python gerar_carteira.py
    python gerar_carteira.py --contratos 5000 --defeitos 0.12 --cedente 341
    python gerar_carteira.py --semente 42        # resultado reproduzivel
"""

import argparse
import csv
import os
import random
from datetime import date, timedelta

PRODUTOS = ["CARTAO", "PESSOAL", "VEICULO", "CHEQUE", "CONSIGNADO"]
UFS = ["SP", "RJ", "MG", "BA", "RS", "PR", "SC", "PE", "CE", "GO", "DF", "ES"]

NOMES = ["ANA", "BRUNO", "CARLA", "DIEGO", "ELAINE", "FABIO", "GABRIELA",
         "HELIO", "ISABELA", "JOAO", "KELLY", "LUCAS", "MARIANA", "NELSON",
         "OLIVIA", "PAULO", "QUEZIA", "RAFAEL", "SANDRA", "TIAGO", "VALERIA"]

SOBRENOMES = ["SILVA", "SANTOS", "OLIVEIRA", "SOUZA", "LIMA", "PEREIRA",
              "COSTA", "RODRIGUES", "ALMEIDA", "NASCIMENTO", "CARVALHO",
              "GOMES", "MARTINS", "ARAUJO", "RIBEIRO", "BRITO"]

CAB_CONTRATO = ["cd_cedente", "nu_contrato", "nu_documento", "nm_devedor",
                "dt_nascimento", "cd_produto", "dt_contratacao", "dt_vencimento",
                "vl_principal", "vl_atualizado", "qt_dias_atraso", "sg_uf",
                "nu_telefone", "ds_email"]

CAB_PARCELA = ["cd_cedente", "nu_contrato", "nu_parcela", "dt_vencimento",
               "vl_parcela", "ds_situacao"]


def digitos_cpf(base):
    """Calcula os dois digitos verificadores de um CPF a partir dos 9 primeiros.

    Precisa ser o mesmo algoritmo implementado em util.fn_valida_cpf no
    script 02. Se os dois divergirem, o pipeline rejeitaria CPFs que o
    gerador considera bons e o teste perderia o sentido.
    """
    soma = sum(int(base[i]) * (10 - i) for i in range(9))
    dv1 = 11 - (soma % 11)
    dv1 = 0 if dv1 >= 10 else dv1

    parcial = base + str(dv1)
    soma = sum(int(parcial[i]) * (11 - i) for i in range(10))
    dv2 = 11 - (soma % 11)
    dv2 = 0 if dv2 >= 10 else dv2

    return f"{base}{dv1}{dv2}"


def cpf_valido():
    base = "".join(str(random.randint(0, 9)) for _ in range(9))
    return digitos_cpf(base)


def cpf_invalido():
    """CPF com 11 digitos mas digito verificador errado.

    Altera so o ultimo digito de um CPF valido. O resultado tem o tamanho
    certo e a cara certa, entao passaria por qualquer validacao que olhe
    apenas o comprimento. So o calculo do verificador pega. E exatamente
    esse o tipo de erro que se quer testar.
    """
    valido = cpf_valido()
    ultimo = str((int(valido[-1]) + 1) % 10)
    return valido[:-1] + ultimo


def formata_cpf(cpf):
    """Metade dos cedentes manda mascarado, metade so os digitos."""
    if random.random() < 0.5:
        return f"{cpf[:3]}.{cpf[3:6]}.{cpf[6:9]}-{cpf[9:]}"
    return cpf


def valor_br(valor):
    """Alterna entre 1234.56 e 1.234,56 de proposito."""
    if random.random() < 0.5:
        return f"{valor:.2f}"
    inteiro, dec = f"{valor:.2f}".split(".")
    partes = []
    while len(inteiro) > 3:
        partes.insert(0, inteiro[-3:])
        inteiro = inteiro[:-3]
    partes.insert(0, inteiro)
    return ".".join(partes) + "," + dec


def data_br(d):
    """Alterna entre dd/MM/yyyy e yyyy-MM-dd de proposito."""
    return d.strftime("%d/%m/%Y") if random.random() < 0.6 else d.strftime("%Y-%m-%d")


def gerar(qtd_contratos, taxa_defeito, cedente, pasta, referencia):
    hoje = date.today()
    linhas_contrato = []
    linhas_parcela = []
    contratos_gerados = []

    for i in range(1, qtd_contratos + 1):
        num_contrato = f"{cedente}{i:08d}"
        com_defeito = random.random() < taxa_defeito

        cpf = cpf_valido()
        nome = f"{random.choice(NOMES)} {random.choice(SOBRENOMES)} {random.choice(SOBRENOMES)}"
        nascimento = hoje - timedelta(days=random.randint(21 * 365, 70 * 365))
        produto = random.choice(PRODUTOS)
        contratacao = hoje - timedelta(days=random.randint(400, 2500))
        atraso = random.randint(95, 1800)
        vencimento = hoje - timedelta(days=atraso)
        principal = round(random.uniform(400, 45000), 2)
        atualizado = round(principal * random.uniform(1.15, 3.2), 2)
        uf = random.choice(UFS)
        telefone = f"({random.randint(11, 99)}) 9{random.randint(1000, 9999)}-{random.randint(1000, 9999)}"
        email = f"{nome.split()[0].lower()}{random.randint(1, 999)}@exemplo.com.br"

        if com_defeito:
            defeito = random.choice([
                "cpf", "nome", "data", "futuro", "principal",
                "atualizado", "atraso", "uf", "produto"
            ])
            if defeito == "cpf":
                cpf = cpf_invalido()
            elif defeito == "nome":
                nome = random.choice(["", "  ", "X"])
            elif defeito == "data":
                contratacao = None
            elif defeito == "futuro":
                contratacao = hoje + timedelta(days=random.randint(5, 400))
            elif defeito == "principal":
                principal = 0
            elif defeito == "atualizado":
                atualizado = round(principal * 0.5, 2)   # gera alerta E006
            elif defeito == "atraso":
                atraso = -random.randint(1, 50)
            elif defeito == "uf":
                uf = random.choice(["XX", "ZZ", ""])
            elif defeito == "produto":
                produto = random.choice(["CARTAO_OURO", "LEASING", ""])

        linhas_contrato.append([
            cedente,
            num_contrato,
            formata_cpf(cpf),
            nome,
            data_br(nascimento),
            produto,
            "DATA_INVALIDA" if contratacao is None else data_br(contratacao),
            data_br(vencimento),
            valor_br(principal),
            valor_br(atualizado),
            str(atraso),
            uf,
            telefone,
            email,
        ])

        contratos_gerados.append(num_contrato)

        # Parcelas do contrato
        for p in range(1, random.randint(1, 6) + 1):
            venc = vencimento + timedelta(days=30 * (p - 1))
            vl = round(atualizado / 6, 2)
            linhas_parcela.append([
                cedente, num_contrato, str(p), data_br(venc),
                valor_br(vl), random.choice(["ABERTA", "ABERTA", "ABERTA", "ACORDO"])
            ])

    # Contratos duplicados no lote (regra E010)
    for _ in range(max(1, qtd_contratos // 100)):
        linhas_contrato.append(list(random.choice(linhas_contrato)))

    # Parcelas orfas, apontando para contrato que nao existe (regra E020)
    for _ in range(max(1, qtd_contratos // 50)):
        linhas_parcela.append([
            cedente, f"{cedente}99999999", "1",
            data_br(hoje - timedelta(days=200)), valor_br(1500.00), "ABERTA"
        ])

    random.shuffle(linhas_contrato)
    random.shuffle(linhas_parcela)

    os.makedirs(pasta, exist_ok=True)
    sufixo = referencia.strftime("%Y%m%d")
    arq_c = os.path.join(pasta, f"CONTRATOS_{cedente}_{sufixo}.csv")
    arq_p = os.path.join(pasta, f"PARCELAS_{cedente}_{sufixo}.csv")

    for caminho, cabecalho, linhas in [
        (arq_c, CAB_CONTRATO, linhas_contrato),
        (arq_p, CAB_PARCELA, linhas_parcela),
    ]:
        with open(caminho, "w", newline="", encoding="utf-8") as f:
            escritor = csv.writer(f, delimiter=";", lineterminator="\n")
            escritor.writerow(cabecalho)
            escritor.writerows(linhas)

    print(f"Gerado: {arq_c}  ({len(linhas_contrato)} linhas)")
    print(f"Gerado: {arq_p}  ({len(linhas_parcela)} linhas)")


def main():
    ap = argparse.ArgumentParser(description="Gera arquivos de carteira NPL para o lab de ETL")
    ap.add_argument("--contratos", type=int, default=2000, help="quantidade de contratos")
    ap.add_argument("--defeitos", type=float, default=0.10, help="proporcao com defeito, 0 a 1")
    ap.add_argument("--cedente", default="237", help="codigo do cedente")
    ap.add_argument("--pasta", default="../arquivos/entrada", help="pasta de saida")
    ap.add_argument("--semente", type=int, default=None, help="semente para resultado reproduzivel")
    args = ap.parse_args()

    if args.semente is not None:
        random.seed(args.semente)

    gerar(args.contratos, args.defeitos, args.cedente, args.pasta, date.today())


if __name__ == "__main__":
    main()
