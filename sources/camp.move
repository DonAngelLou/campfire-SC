/// CAMP token - Native currency for the Campfire reputation platform
module campfire::camp {
    use std::option;
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;

    /// One-time witness for CAMP currency creation (ensures single TreasuryCap)
    public struct CAMP has drop {}

    /// Initialize CAMP currency. Called once at package publish.
    /// Transfers TreasuryCap and CoinMetadata to the publisher.
    fun init(ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            CAMP {},
            9, // decimals (same as SUI for consistency)
            b"CAMP",
            b"Campfire Token",
            b"Native token for the Campfire reputation and verification platform",
            option::none(),
            ctx,
        );
        transfer::transfer(treasury_cap, tx_context::sender(ctx));
        transfer::transfer(metadata, tx_context::sender(ctx));
    }
}
