/// CAMP token - Native currency for the Campfire reputation platform
#[allow(deprecated_usage)]
module campfire::camp {
    use sui::coin;

    /// One-time witness for CAMP currency creation (ensures single TreasuryCap)
    public struct CAMP has drop {}

    /// Initialize CAMP currency. Called once at package publish.
    /// Transfers TreasuryCap and CoinMetadata to the publisher.
    fun init(witness: CAMP, ctx: &mut tx_context::TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // decimals (same as SUI for consistency)
            b"CAMP",
            b"Campfire Token",
            b"Native token for the Campfire reputation and verification platform",
            std::option::none(),
            ctx,
        );
        sui::transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
        sui::transfer::public_transfer(metadata, tx_context::sender(ctx));
    }
}
