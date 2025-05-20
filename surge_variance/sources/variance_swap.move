module surge_variance::variance_swap {
    use sui::object::{Self, ID, UID};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance, Supply};
    use sui::event;
    
    // Error codes
    const EMarketExpired: u64 = 1;
    const ENumberOverflow: u64 = 2;
    
    // Structs for tokens
    struct VAR_LONG has drop {}
    struct VAR_SHORT has drop {}
    
    // Market state
    struct Market<phantom CoinType> has key, store {
        id: UID,
        epoch: u64,
        strike: u64,  // Using integer for simplified math (strike * 100)
        timestamp: u64,
        authority: address,
        usdc_vault: Balance<CoinType>,
        var_long_supply: Supply<VAR_LONG>,
        var_short_supply: Supply<VAR_SHORT>,
        start_volatility: u64,  // Using integer for simplified math (vol * 100)
        is_initialized: bool,
        is_expired: bool,
        realized_variance: u64,  // Using integer for simplified math (variance * 100)
        total_deposits: u64,
    }
    
    // Token representation
    struct TokenPair<phantom CoinType> has key, store {
        id: UID,
        market_id: ID,
        long_tokens: Balance<VAR_LONG>,
        short_tokens: Balance<VAR_SHORT>,
    }
    
    // Events
    struct MarketInitialized has copy, drop {
        market_id: ID,
        authority: address,
        epoch: u64,
        strike: u64,
        timestamp: u64,
        start_volatility: u64,
    }
    
    struct TokensMinted has copy, drop {
        market_id: ID,
        user: address,
        amount: u64,
        is_long: bool,
        total_deposits: u64,
    }
    
    struct MarketRedeemed has copy, drop {
        market_id: ID,
        user: address,
        realized_variance: u64,
        strike: u64,
        long_payout: u64,
        short_payout: u64,
        total_deposits: u64,
    }
    
    // Initialize market
    public fun initialize_market<CoinType>(
        epoch: u64,
        strike: u64,
        timestamp: u64,
        start_volatility: u64,
        ctx: &mut TxContext
    ): Market<CoinType> {
        // Create token supplies
        let var_long = VAR_LONG {};
        let var_short = VAR_SHORT {};
        
        let market = Market {
            id: object::new(ctx),
            epoch,
            strike,
            timestamp,
            authority: tx_context::sender(ctx),
            usdc_vault: balance::zero(),
            var_long_supply: balance::create_supply(var_long),
            var_short_supply: balance::create_supply(var_short),
            start_volatility,
            is_initialized: true,
            is_expired: false,
            realized_variance: 0,
            total_deposits: 0,
        };
        
        event::emit(MarketInitialized {
            market_id: object::id(&market),
            authority: market.authority,
            epoch: market.epoch,
            strike: market.strike,
            timestamp: market.timestamp,
            start_volatility: market.start_volatility,
        });
        
        market
    }
    
    // Mint tokens
    public fun mint_tokens<CoinType>(
        market: &mut Market<CoinType>,
        amount: u64,
        is_long: bool,
        usdc_payment: Coin<CoinType>,
        ctx: &mut TxContext
    ): TokenPair<CoinType> {
        // Check if market is expired based on time
        let current_time = tx_context::epoch(ctx);
        let is_time_expired = current_time > market.timestamp + market.epoch;
        assert!(!is_time_expired, EMarketExpired);
        
        // Transfer USDC to market vault
        let payment_balance = coin::into_balance(usdc_payment);
        let payment_amount = balance::value(&payment_balance);
        assert!(payment_amount == amount, ENumberOverflow);
        
        balance::join(&mut market.usdc_vault, payment_balance);
        
        // Create token pair for the user
        let token_pair = TokenPair<CoinType> {
            id: object::new(ctx),
            market_id: object::id(market),
            long_tokens: balance::zero(),
            short_tokens: balance::zero(),
        };
        
        // Mint VAR tokens to user
        if (is_long) {
            // Mint new tokens by increasing supply
            let minted_tokens = balance::increase_supply(&mut market.var_long_supply, amount);
            balance::join(&mut token_pair.long_tokens, minted_tokens);
        } else {
            // Mint new tokens by increasing supply
            let minted_tokens = balance::increase_supply(&mut market.var_short_supply, amount);
            balance::join(&mut token_pair.short_tokens, minted_tokens);
        };
        
        market.total_deposits = market.total_deposits + amount;
        
        // Emit event
        event::emit(TokensMinted {
            market_id: object::id(market),
            user: tx_context::sender(ctx),
            amount,
            is_long,
            total_deposits: market.total_deposits,
        });
        
        token_pair
    }
    
    // Redeem tokens
    public fun redeem<CoinType>(
        market: &mut Market<CoinType>,
        token_pair: TokenPair<CoinType>,
        current_volatility: u64,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        // Check if market is expired based on time
        let current_time = tx_context::epoch(ctx);
        let is_time_expired = current_time > market.timestamp + market.epoch;
        
        // Only allow redemption after market has expired (matured)
        assert!(is_time_expired, EMarketExpired);
        
        // Calculate realized variance from the provided current volatility
        let realized_variance = if (current_volatility > market.start_volatility) {
            current_volatility - market.start_volatility
        } else {
            0
        };
        
        market.realized_variance = realized_variance;
        
        // Calculate payouts
        let total_supply = market.total_deposits;
        let strike = market.strike;
        
        let long_payout = if (realized_variance > strike) {
            let variance_diff = realized_variance - strike;
            // Simplified calculation: (variance_diff * total_supply) / 100
            let variance_diff_u128 = (variance_diff as u128);
            let total_supply_u128 = (total_supply as u128);
            (variance_diff_u128 * total_supply_u128) / 100
        } else {
            0
        };
        
        let long_payout = (long_payout as u64);
        let short_payout = total_supply - long_payout;
        
        // Extract token pair components
        let TokenPair { id, market_id: _, long_tokens, short_tokens } = token_pair;
        
        let long_amount = balance::value(&long_tokens);
        let short_amount = balance::value(&short_tokens);
        
        // Calculate total payout
        let total_payout = 
            if (long_amount > 0 && long_payout > 0) {
                let long_amount_u128 = (long_amount as u128);
                let long_payout_u128 = (long_payout as u128);
                let total_supply_u128 = (total_supply as u128);
                (long_amount_u128 * long_payout_u128) / total_supply_u128
            } else {
                0
            };
        
        let total_payout = total_payout + 
            if (short_amount > 0 && short_payout > 0) {
                let short_amount_u128 = (short_amount as u128);
                let short_payout_u128 = (short_payout as u128);
                let total_supply_u128 = (total_supply as u128);
                (short_amount_u128 * short_payout_u128) / total_supply_u128
            } else {
                0
            };
        
        // Properly destroy token balances by decreasing supply
        if (long_amount > 0) {
            let _ = balance::decrease_supply(&mut market.var_long_supply, long_tokens);
        } else {
            balance::destroy_zero(long_tokens);
        };
        
        if (short_amount > 0) {
            let _ = balance::decrease_supply(&mut market.var_short_supply, short_tokens);
        } else {
            balance::destroy_zero(short_tokens);
        };
        
        // Delete the ID
        object::delete(id);
        
        // Transfer payout to user
        let payout = balance::split(&mut market.usdc_vault, (total_payout as u64));
        
        // Emit event
        event::emit(MarketRedeemed {
            market_id: object::id(market),
            user: tx_context::sender(ctx),
            realized_variance,
            strike,
            long_payout,
            short_payout,
            total_deposits: total_supply,
        });
        
        // Return USDC to user
        coin::from_balance(payout, ctx)
    }
    
    // Public entry functions for contract interaction
    
    public entry fun create_market<CoinType>(
        epoch: u64,
        strike: u64,
        timestamp: u64,
        start_volatility: u64,
        ctx: &mut TxContext
    ) {
        let market = initialize_market<CoinType>(
            epoch, 
            strike, 
            timestamp, 
            start_volatility, 
            ctx
        );
        
        transfer::share_object(market);
    }
    
    public entry fun deposit_and_mint<CoinType>(
        market: &mut Market<CoinType>,
        amount: u64,
        is_long: bool,
        usdc_payment: Coin<CoinType>,
        ctx: &mut TxContext
    ) {
        let token_pair = mint_tokens(market, amount, is_long, usdc_payment, ctx);
        transfer::public_transfer(token_pair, tx_context::sender(ctx));
    }
    
    public entry fun withdraw_and_redeem<CoinType>(
        market: &mut Market<CoinType>,
        token_pair: TokenPair<CoinType>,
        current_volatility: u64,
        ctx: &mut TxContext
    ) {
        let payout = redeem(market, token_pair, current_volatility, ctx);
        transfer::public_transfer(payout, tx_context::sender(ctx));
    }
}