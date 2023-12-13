{{
    config(
        schema = 'pancakeswap_bnb',
        alias = 'base_trades',
        materialized = 'incremental',
        file_format = 'delta',
        incremental_strategy = 'merge',
        unique_key = ['tx_hash', 'evt_index'],
        incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')]
    )
}}

WITH 

dexs_macro AS (
    -- PancakeSwap v2
    {{
        uniswap_compatible_v2_trades(
            blockchain = 'bnb',
            project = 'pancakeswap',
            version = '2',
            Pair_evt_Swap = source('pancakeswap_v2_bnb', 'PancakePair_evt_Swap'),
            Factory_evt_PairCreated = source('pancakeswap_v2_bnb', 'PancakeFactory_evt_PairCreated')
        )
    }}
),

dexs AS (
    -- PancakeSwap v2 MMPool
    SELECT
        'mmpool' AS version,
        t.evt_block_number AS block_number,
        t.evt_block_time AS block_time,
        t.user AS taker,
        t.mm AS maker,
        quoteTokenAmount AS token_bought_amount_raw,
        baseTokenAmount AS token_sold_amount_raw,
        CASE WHEN quotetoken  = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 
             THEN 0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c ELSE quotetoken END AS token_bought_address,
        CASE WHEN basetoken  = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 
             THEN 0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c ELSE basetoken END AS token_sold_address,     
        t.contract_address AS project_contract_address,
        t.evt_tx_hash AS tx_hash,
        t.evt_index
    FROM {{ source('pancakeswap_v2_bnb', 'PancakeSwapMMPool_evt_Swap') }} t
    {% if is_incremental() %}
    WHERE {{ incremental_predicate('t.evt_block_time') }}
    {% endif %}

    UNION ALL

    -- PancakeSwap v2 stableswap
    SELECT
        'stableswap' AS version,
        t.evt_block_number AS block_number,
        t.evt_block_time AS block_time,
        t.buyer AS taker, 
        CAST(NULL AS VARBINARY) AS maker,
        tokens_bought AS token_bought_amount_raw,
        tokens_sold AS token_sold_amount_raw,
        CASE WHEN bought_id = UINT256 '0' THEN f.tokenA ELSE f.tokenB END AS token_bought_address,
        CASE WHEN bought_id = UINT256 '0' THEN f.tokenB ELSE f.tokenA END AS token_sold_address,
        t.contract_address AS project_contract_address,
        t.evt_tx_hash AS tx_hash,
        t.evt_index
    FROM
        (
            SELECT * FROM {{ source('pancakeswap_v2_bnb', 'PancakeStableSwap_evt_TokenExchange') }}
            UNION ALL
            SELECT * FROM {{ source('pancakeswap_v2_bnb', 'PancakeStableSwapTwoPool_evt_TokenExchange') }}   
        ) t
    INNER JOIN (
            SELECT a.*
            FROM {{ source('pancakeswap_v2_bnb', 'PancakeStableSwapFactory_evt_NewStableSwapPair') }} a
            INNER JOIN (
              SELECT swapContract, MAX(evt_block_time) AS latest_time
              FROM {{ source('pancakeswap_v2_bnb', 'PancakeStableSwapFactory_evt_NewStableSwapPair') }}
              GROUP BY swapContract
            ) b
            ON a.swapContract = b.swapContract AND a.evt_block_time = b.latest_time
        ) f
    ON t.contract_address = f.swapContract
    {% if is_incremental() %}
    WHERE {{ incremental_predicate('t.evt_block_time') }}
    {% endif %}
)

SELECT
    dexs_macro.blockchain,
    dexs_macro.project,
    dexs_macro.version,
    dexs_macro.block_month,
    dexs_macro.block_date,
    dexs_macro.block_time,
    dexs_macro.block_number,
    dexs_macro.token_bought_amount_raw,
    dexs_macro.token_sold_amount_raw,
    dexs_macro.token_bought_address,
    dexs_macro.token_sold_address,
    dexs_macro.taker,
    dexs_macro.maker,
    dexs_macro.project_contract_address,
    dexs_macro.tx_hash,
    dexs_macro.evt_index
FROM dexs_macro
UNION ALL
SELECT
    'bnb' AS blockchain,
    'pancakeswap' AS project,
    dexs.version,
    CAST(date_trunc('month', dexs.block_time) AS date) AS block_month,
    CAST(date_trunc('day', dexs.block_time) AS date) AS block_date,
    dexs.block_time,
    dexs.block_number,
    dexs.token_bought_amount_raw,
    dexs.token_sold_amount_raw,
    dexs.token_bought_address,
    dexs.token_sold_address,
    dexs.taker,
    dexs.maker,
    dexs.project_contract_address,
    dexs.tx_hash,
    dexs.evt_index
FROM dexs
