-- =========================================================
-- PROJETO: Análise de Clientes com Pagamentos Vencidos
-- CONTEXTO: Plataforma SaaS com cobrança recorrente
-- OBJETIVO: Identificar clientes inadimplentes e risco de churn
-- =========================================================

-- Data inicial da análise
SET @data_inicio_analise := '2024-07-11';

-- Data atual
SET @data_atual := CURDATE();


SELECT
    MAX(c.id_cliente) AS id_cliente,

    -- =========================================================
    -- Regra de cálculo de vencimento:
    -- Se o cliente não pertence a uma empresa, usa o vencimento padrão
    -- Caso contrário, ajusta para o dia de faturamento da empresa
    -- =========================================================
    IF(
        MAX(emp.dia_faturamento) IS NULL,
        MAX(pag.data_vencimento),
        DATE_ADD(
            MAX(pag.data_vencimento),
            INTERVAL -DAY(MAX(pag.data_vencimento)) + MAX(emp.dia_faturamento) DAY
        )
    ) AS data_vencimento_ajustada,

    -- Data de início da assinatura
    MAX(COALESCE(ass.data_inicio, ass.data_inicio_anterior)) AS data_inicio_assinatura,

    -- Valor da cobrança
    MAX(pag.valor) AS valor,

    -- Status da assinatura (destacando inadimplentes)
    IF(
        MAX(ass.id_status) = 4,
        'inadimplente',
        MAX(st.descricao)
    ) AS status_assinatura,

    -- Dados do cliente
    MAX(cli.data_nascimento) AS data_nascimento,

    -- Empresa vinculada (B2B)
    MAX(emp.id_empresa) AS id_empresa,

    -- Quantidade de parcelas pendentes
    COALESCE(pp.qtd_pendentes, 0) AS qtd_parcelas_pendentes,

    -- Último motivo de cancelamento/exclusão
    ue.data_evento AS data_ultimo_cancelamento,
    ue.descricao_evento AS motivo_ultimo_cancelamento

FROM pagamentos_recorrentes pag

-- =========================================================
-- SUBQUERY: Contagem de parcelas pendentes por conta
-- =========================================================
LEFT JOIN (
    SELECT
        pag2.id_conta,
        COUNT(*) AS qtd_pendentes
    FROM pagamentos_recorrentes pag2
    JOIN contas c2 ON pag2.id_conta = c2.id_conta

    LEFT JOIN empresa_clientes ec2 ON ec2.id_cliente = c2.id_cliente
    LEFT JOIN empresas emp2 ON emp2.id_empresa = ec2.id_empresa

    WHERE
        c2.tipo_conta = 'ASSINATURA'
        AND pag2.tipo_pagamento = 'RECORRENTE'

        -- Aplicando mesma regra de vencimento
        AND IF(
            emp2.id_empresa IS NULL,
            pag2.data_vencimento,
            DATE_ADD(
                pag2.data_vencimento,
                INTERVAL -DAY(pag2.data_vencimento) + emp2.dia_faturamento DAY
            )
        ) < @data_atual

        AND pag2.cancelado = 0
        AND pag2.status = 'PENDENTE'

    GROUP BY pag2.id_conta
) pp
ON pp.id_conta = pag.id_conta,

assinaturas ass

-- =========================================================
-- SUBQUERY: Últimos eventos de cancelamento/exclusão
-- =========================================================
LEFT JOIN (
    SELECT
        ev.id_cliente,
        ev.data_evento,
        tp.descricao AS descricao_evento
    FROM eventos_assinatura ev
    JOIN tipos_evento tp ON ev.id_tipo_evento = tp.id_tipo_evento
    WHERE tp.codigo IN (
        'CANCELAMENTO_USUARIO',
        'CANCELAMENTO_INADIMPLENCIA',
        'DESISTENCIA',
        'CONDICAO_PREEXISTENTE',
        'NAO_RENOVACAO',
        'FIM_CONTRATO'
    )
) ue
ON ue.id_cliente = ass.id_cliente
AND ass.id_status IN (6,7,10),

status_assinatura st,
clientes cli,
configuracao_pagamento cfg,
contas c

LEFT JOIN empresa_clientes ec ON ec.id_cliente = c.id_cliente
LEFT JOIN empresas emp ON emp.id_empresa = ec.id_empresa

WHERE
    pag.id_conta = c.id_conta
    AND c.tipo_conta = 'ASSINATURA'

    -- Relacionamento com assinatura
    AND c.id_cliente = ass.id_cliente
    AND ass.id_status = st.id_status

    -- Relacionamento com cliente
    AND ass.id_cliente = cli.id_cliente

    -- Configuração de pagamento
    AND pag.id_configuracao = cfg.id_configuracao
    AND cfg.tipo_pagamento = 'RECORRENTE'

    -- =========================================================
    -- Filtro por período de vencimento
    -- =========================================================
    AND IF(
        emp.id_empresa IS NULL,
        pag.data_vencimento,
        DATE_ADD(
            pag.data_vencimento,
            INTERVAL -DAY(pag.data_vencimento) + emp.dia_faturamento DAY
        )
    ) BETWEEN @data_inicio_analise AND DATE_ADD(@data_atual, INTERVAL -1 DAY)

    -- Apenas clientes ativos
    AND cli.ativo = TRUE

    -- Pagamentos válidos
    AND pag.cancelado = 0

    -- Regras de negócio (inadimplência e cancelamentos)
    AND (
        (ass.id_status IN (4,5) AND pag.status = 'PENDENTE')
        OR ass.id_status IN (6,7)
    )

GROUP BY pag.id_conta

-- =========================================================
-- Ordenação por prioridade:
-- 1. Inadimplentes
-- 2. Pendentes
-- 3. Outros
-- =========================================================
ORDER BY
    IF(MAX(ass.id_status) = 4, 1,
        IF(MAX(ass.id_status) = 5, 2, 3)
    ),

    -- Ordenação por vencimento ajustado
    IF(
        MAX(emp.id_empresa) IS NULL,
        MAX(pag.data_vencimento),
        DATE_ADD(
            MAX(pag.data_vencimento),
            INTERVAL -DAY(MAX(pag.data_vencimento)) + MAX(emp.dia_faturamento) DAY
        )
    ),

    c.id_cliente;
