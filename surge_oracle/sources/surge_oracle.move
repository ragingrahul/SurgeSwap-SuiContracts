module surge_oracle::vol_oracle {
    use sui::tx_context::sender;
    use sui::tx_context::TxContext;
    use sui::object::Self;
    use sui::object::UID;
    use sui::clock::Clock;
    use sui::event;
    use sui::transfer;

    use pyth::price_info::{Self as PI, PriceInfoObject};
    use pyth::price_identifier;
    use pyth::price;
    use pyth::i64;
    use pyth::pyth;

    const SUI_FEED_ID: vector<u8> = x"50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";
    const MAX_AGE_SEC: u64 = 60;

    const E_INVALID_FEED: u64 = 1;

    public struct VolatilityStats has key, store {
        id: UID,
        authority: address,

        last_price_u6: u64,
        mean_fp: u64,
        m2_fp: u128,
        count: u64,
        ann_vol_fp: u64,
    }

    public struct VolatilityUpdated has copy, drop, store {
        current_price_u6: u64,
        mean_fp: u64,
        m2_fp: u128,
        count: u64,
        ann_vol_fp: u64,
    }

    public fun get_last_price_u6(stats: &VolatilityStats): u64 {
        stats.last_price_u6
    }
    
    public fun get_mean_fp(stats: &VolatilityStats): u64 {
        stats.mean_fp
    }
    
    public fun get_m2_fp(stats: &VolatilityStats): u128 {
        stats.m2_fp
    }
    
    public fun get_count(stats: &VolatilityStats): u64 {
        stats.count
    }
    
    public fun get_ann_vol_fp(stats: &VolatilityStats): u64 {
        stats.ann_vol_fp
    }
    
    public fun get_authority(stats: &VolatilityStats): address {
        stats.authority
    }

    public entry fun initialize(ctx: &mut TxContext) {
        let stats = VolatilityStats {
            id: object::new(ctx),
            authority: sender(ctx),

            last_price_u6: 0,
            mean_fp: 0,
            m2_fp: 0,
            count: 0,
            ann_vol_fp: 0,
        };
        
        transfer::public_share_object(stats);
    }

    public entry fun update_volatility(
        stats: &mut VolatilityStats,
        clock: &Clock,
        price_obj: &PriceInfoObject,
    ) {
        let price_struct = pyth::get_price_no_older_than(
            price_obj,
            clock,
            MAX_AGE_SEC
        );

        let info = PI::get_price_info_from_price_info_object(price_obj);
        let feed_id = price_identifier::get_bytes(&PI::get_price_identifier(&info));

        assert!(feed_id == SUI_FEED_ID, E_INVALID_FEED);

        let price_i64 = price::get_price(&price_struct);
        
        let price_magnitude;
        let is_negative = i64::get_is_negative(&price_i64);
        
        if (is_negative) {
            price_magnitude = i64::get_magnitude_if_negative(&price_i64);
        } else {
            price_magnitude = i64::get_magnitude_if_positive(&price_i64);
        };
        
        let curr_u6 = price_magnitude;

        let mean = stats.mean_fp;
        let m2 = stats.m2_fp;
        let n = stats.count;
        let ann_vol = stats.ann_vol_fp;

        let updated_mean;
        let updated_m2;
        let updated_ann_vol;
        let updated_n;

        if (n > 0) {
            updated_n = n + 1;
            let percent_change = if (stats.last_price_u6 == 0) {
                0u64
            } else {
                if (curr_u6 > stats.last_price_u6) {
                    let change = ((curr_u6 - stats.last_price_u6) as u128) * 1000000 / (stats.last_price_u6 as u128);
                    if (change > 18446744073709551615) { 1000000 } else { (change as u64) }
                } else {
                    let change = ((stats.last_price_u6 - curr_u6) as u128) * 1000000 / (stats.last_price_u6 as u128);
                    if (change > 18446744073709551615) { 1000000 } else { (change as u64) }
                }
            };
            
            let mean_delta = percent_change / updated_n;
            updated_mean = if (updated_n == 0) { 
                mean 
            } else if (mean > (18446744073709551615 - mean_delta)) {
                18446744073709551615
            } else { 
                mean + mean_delta
            };
            
            let delta = (percent_change as u128);
            let delta_squared = delta * delta;
            updated_m2 = if (m2 > (340282366920938463463374607431768211455 - delta_squared)) {
                m2
            } else {
                m2 + delta_squared
            };

            if (updated_n > 1) {
                let var_fp = updated_m2 / ((updated_n - 1) as u128);
                let bounded_var = if (var_fp > 1000000000000000000) { 
                    1000000000000000000 
                } else { 
                    var_fp 
                };
                
                let daily_vol = safe_sqrt(bounded_var);
                updated_ann_vol = if (daily_vol > (18446744073709551615 / 15874)) {
                    18446744073709551615
                } else {
                    (daily_vol * 15874) / 10000
                };
            } else {
                updated_ann_vol = ann_vol;
            };
        } else {
            updated_n = 1;
            updated_mean = 0;
            updated_m2 = 0;
            updated_ann_vol = 0;
        };

        stats.last_price_u6 = curr_u6;
        stats.mean_fp = updated_mean;
        stats.m2_fp = updated_m2;
        stats.count = updated_n;
        stats.ann_vol_fp = updated_ann_vol;

        event::emit(VolatilityUpdated {
            current_price_u6: curr_u6,
            mean_fp: updated_mean,
            m2_fp: updated_m2,
            count: updated_n,
            ann_vol_fp: updated_ann_vol,
        });
    }

    fun safe_sqrt(x: u128): u64 {
        if (x == 0) { 
            return 0 
        };
        if (x > 1000000000000000000) { 
            return 1000000 
        };
        
        let guess: u128 = 1000;
        let iteration_count = 0;
        
        safe_newton_iteration(x, guess, iteration_count)
    }
    
    fun safe_newton_iteration(x: u128, guess: u128, iteration_count: u64): u64 {
        if (iteration_count > 10) {
            return (guess as u64)
        };
        
        let new_guess = if (guess == 0) {
            1
        } else {
            let division_result = x / guess;
            let sum = division_result + guess;
            sum / 2
        };
        
        if (new_guess == guess) {
            return (new_guess as u64)
        };
        
        safe_newton_iteration(x, new_guess, iteration_count + 1)
    }
}