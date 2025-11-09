module campfire::CampfireBadge {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;
    use std::string::{Self, String};

    // ==================== ERRORS ===================
    
    const ENotAdmin: u64 = 0;
    const EInvalidFee: u64 = 1;
    const ENotIssuer: u64 = 2;
    const EPaymentMismatch: u64 = 3;

    // ==================== STRUCTS ====================

    /// Platform configuration (shared object)
    struct PlatformConfig has key {
        id: UID,
        admin: address,
        treasury: address,
        platform_fee_percent: u64,
    }

    /// Badge NFT - The actual achievement token
    struct BadgeNFT has key, store {
        id: UID,
        name: String,
        description: String,
        rank: String,
        image_url: String,
        issuer: address,
        original_minter: address,
        awarded_at: u64,
        metadata_uri: String,
    }

    // ==================== EVENTS ====================

    struct BadgeMintedEvent has copy, drop {
        badge_id: address,
        recipient: address,
        issuer: address,
        name: String,
        rank: String,
        price_paid: u64,
    }

    struct BadgeAwardedEvent has copy, drop {
        badge_id: address,
        recipient: address,
        issuer: address,
        name: String,
        rank: String,
    }

    struct BadgeTransferredEvent has copy, drop {
        badge_id: address,
        from: address,
        to: address,
        royalty_paid: u64,
    }

    // ==================== INIT ====================

    fun init(ctx: &mut TxContext) {
        let config = PlatformConfig {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            treasury: tx_context::sender(ctx),
            platform_fee_percent: 10,
        };
        transfer::share_object(config);
    }

    // ==================== ADMIN FUNCTIONS ====================

    entry fun update_treasury(
        config: &mut PlatformConfig,
        new_treasury: address,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == config.admin, ENotAdmin);
        config.treasury = new_treasury;
    }

    entry fun update_fee(
        config: &mut PlatformConfig,
        new_fee: u64,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == config.admin, ENotAdmin);
        assert!(new_fee <= 100, EInvalidFee);
        config.platform_fee_percent = new_fee;
    }

    // ==================== MINTING FUNCTIONS ====================

    entry fun mint_badge_paid(
        config: &PlatformConfig,
        payment: Coin<SUI>,
        expected_price: u64,
        recipient: address,
        issuer: address,
        name: vector<u8>,
        description: vector<u8>,
        rank: vector<u8>,
        image_url: vector<u8>,
        metadata_uri: vector<u8>,
        ctx: &mut TxContext
    ) {
        let actual_payment = coin::value(&payment);
        assert!(actual_payment == expected_price, EPaymentMismatch);
        
        let platform_fee = (expected_price * config.platform_fee_percent) / 100;
        let platform_coin = coin::split(&mut payment, platform_fee, ctx);
        
        transfer::public_transfer(platform_coin, config.treasury);
        transfer::public_transfer(payment, issuer);

        let badge = BadgeNFT {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            rank: string::utf8(rank),
            image_url: string::utf8(image_url),
            issuer,
            original_minter: recipient,
            awarded_at: tx_context::epoch(ctx),
            metadata_uri: string::utf8(metadata_uri),
        };

        let badge_id = object::uid_to_address(&badge.id);

        event::emit(BadgeMintedEvent {
            badge_id,
            recipient,
            issuer,
            name: badge.name,
            rank: badge.rank,
            price_paid: expected_price,
        });

        transfer::public_transfer(badge, recipient);
    }

    entry fun award_badge_free(
        recipient: address,
        issuer: address,
        name: vector<u8>,
        description: vector<u8>,
        rank: vector<u8>,
        image_url: vector<u8>,
        metadata_uri: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == issuer, ENotIssuer);

        let badge = BadgeNFT {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            rank: string::utf8(rank),
            image_url: string::utf8(image_url),
            issuer,
            original_minter: recipient,
            awarded_at: tx_context::epoch(ctx),
            metadata_uri: string::utf8(metadata_uri),
        };

        let badge_id = object::uid_to_address(&badge.id);

        event::emit(BadgeAwardedEvent {
            badge_id,
            recipient,
            issuer,
            name: badge.name,
            rank: badge.rank,
        });

        transfer::public_transfer(badge, recipient);
    }

    // ==================== TRANSFER WITH ROYALTIES ====================

    entry fun transfer_badge_with_royalty(
        config: &PlatformConfig,
        badge: BadgeNFT,
        payment: Coin<SUI>,
        new_owner: address,
        ctx: &mut TxContext
    ) {
        let sale_price = coin::value(&payment);
        let badge_id = object::uid_to_address(&badge.id);
        let original_minter = badge.original_minter;
        let from = tx_context::sender(ctx);

        let creator_royalty = (sale_price * 5) / 100;
        let platform_fee = (sale_price * config.platform_fee_percent) / 100;

        let creator_coin = coin::split(&mut payment, creator_royalty, ctx);
        let platform_coin = coin::split(&mut payment, platform_fee, ctx);
        
        transfer::public_transfer(creator_coin, original_minter);
        transfer::public_transfer(platform_coin, config.treasury);
        transfer::public_transfer(payment, from);

        event::emit(BadgeTransferredEvent {
            badge_id,
            from,
            to: new_owner,
            royalty_paid: creator_royalty,
        });

        transfer::public_transfer(badge, new_owner);
    }

    // ==================== VIEW FUNCTIONS ====================

    public fun get_badge_info(badge: &BadgeNFT): (String, String, String, address, address, u64) {
        (
            badge.name,
            badge.description,
            badge.rank,
            badge.issuer,
            badge.original_minter,
            badge.awarded_at
        )
    }

    public fun get_platform_fee(config: &PlatformConfig): u64 {
        config.platform_fee_percent
    }

    public fun get_badge_name(badge: &BadgeNFT): String {
        badge.name
    }

    public fun get_badge_rank(badge: &BadgeNFT): String {
        badge.rank
    }

    public fun get_badge_issuer(badge: &BadgeNFT): address {
        badge.issuer
    }

    public fun get_badge_original_minter(badge: &BadgeNFT): address {
        badge.original_minter
    }
}