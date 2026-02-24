/// Campfire Badge - Reputation registry, certificates (soulbound), awards (tradable), vouching
module campfire::CampfireBadge {
    use campfire::camp::CAMP;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;
    use sui::table::{Self, Table};
    use std::string::{Self, String};

    // ==================== VERSION (for upgrade pattern) ====================
    const VERSION: u64 = 1;

    // ==================== ERRORS ====================

    const ENotAdmin: u64 = 0;
    const EInvalidFee: u64 = 1;
    const ENotIssuer: u64 = 2;
    const EPaymentMismatch: u64 = 3;
    const EWrongVersion: u64 = 4;
    const ENotUpgrade: u64 = 5;
    const ENotVoucherTier: u64 = 6;
    const ENothPending: u64 = 7;
    const EInsufficientVerified: u64 = 8;
    const EAlreadyTier1: u64 = 10;
    const ENotTier1: u64 = 12;
    const ESlashed: u64 = 13;
    const ENotRecruiterTier: u64 = 14;

    // ==================== CONSTANTS (defaults, overridable via config) ====================
    const DEFAULT_PLATFORM_FEE_PERCENT: u64 = 10;
    const TIER1_MIN_VERIFIED: u64 = 3;
    const TIER2_MIN_VERIFIED: u64 = 10;
    const TIER3_MIN_VERIFIED: u64 = 25;
    const TIER2_PAID_MIN_VERIFIED: u64 = 3;
    const VOUCHER_SHARE_PERCENT: u64 = 70;
    const PLATFORM_SHARE_PERCENT: u64 = 30;
    const CREATOR_ROYALTY_PERCENT: u64 = 5;
    const TIER_UPGRADE_TREASURY_PERCENT: u64 = 50;
    const TIER_UPGRADE_BURN_PERCENT: u64 = 50;

    // ==================== STRUCTS ====================

    /// Admin capability for migrate and config updates
    struct AdminCap has key {
        id: UID,
    }

    /// User record in the reputation registry
    struct UserRecord has store, copy, drop {
        tier: u8,
        verified_cert_count: u64,
        slashed_until_epoch: u64,
    }

    /// Reputation registry and platform config (shared object)
    struct ReputationRegistry has key {
        id: UID,
        version: u64,
        admin: address,
        admin_cap_id: sui::object::ID,
        treasury: address,
        platform_fee_percent: u64,
        user_registry: Table<address, UserRecord>,
        // Configurable fees (in CAMP smallest units)
        tier1_activation_fee: u64,
        tier2_levelup_fee: u64,
        vouching_fee: u64,
        tier1_min_verified: u64,
        tier2_min_verified: u64,
        tier3_min_verified: u64,
        tier2_paid_min_verified: u64,
        voucher_share_percent: u64,
        platform_share_percent: u64,
        tier_upgrade_treasury_percent: u64,
        tier_upgrade_burn_percent: u64,
    }

    /// Soulbound certificate - credentials (no store = not transferable)
    struct Certificate has key {
        id: UID,
        name: String,
        description: String,
        rank: String, // "Pending" or "Verified"
        image_url: String,
        issuer: address,
        owner: address,
        awarded_at: u64,
        metadata_uri: String,
        walrus_blob_id: String,   // Walrus blob ID for high-res assets
        encrypted_blob_id: String, // Seal encrypted blob ID if sensitive
    }

    /// Tradable award or ticket (has store = transferable with royalties)
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

    struct CertificateMintedEvent has copy, drop {
        certificate_id: address,
        owner: address,
        issuer: address,
        name: String,
        rank: String,
        is_native: bool,
    }

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

    struct BadgeVerifiedEvent has copy, drop {
        certificate_id: address,
        voucher: address,
        owner: address,
    }

    struct TierChangedEvent has copy, drop {
        user: address,
        old_tier: u8,
        new_tier: u8,
    }

    struct VoucherSlashedEvent has copy, drop {
        voucher: address,
        new_tier: u8,
    }

    struct SealAccessRequestedEvent has copy, drop {
        certificate_id: address,
        requester: address,
        epoch: u64,
    }

    // ==================== INIT ====================

    fun init(ctx: &mut TxContext) {
        let admin = tx_context::sender(ctx);
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        let admin_cap_id = object::id(&admin_cap);

        let user_registry = table::new<address, UserRecord>(ctx);

        let config = ReputationRegistry {
            id: object::new(ctx),
            version: VERSION,
            admin,
            admin_cap_id,
            treasury: admin,
            platform_fee_percent: DEFAULT_PLATFORM_FEE_PERCENT,
            user_registry,
            tier1_activation_fee: 1_000_000_000, // 1 CAMP (9 decimals)
            tier2_levelup_fee: 10_000_000_000,  // 10 CAMP
            vouching_fee: 500_000_000,           // 0.5 CAMP
            tier1_min_verified: TIER1_MIN_VERIFIED,
            tier2_min_verified: TIER2_MIN_VERIFIED,
            tier3_min_verified: TIER3_MIN_VERIFIED,
            tier2_paid_min_verified: TIER2_PAID_MIN_VERIFIED,
            voucher_share_percent: VOUCHER_SHARE_PERCENT,
            platform_share_percent: PLATFORM_SHARE_PERCENT,
            tier_upgrade_treasury_percent: TIER_UPGRADE_TREASURY_PERCENT,
            tier_upgrade_burn_percent: TIER_UPGRADE_BURN_PERCENT,
        };

        transfer::share_object(config);
        transfer::transfer(admin_cap, admin);
    }

    // ==================== HELPERS ====================

    fun ensure_user_registry(config: &mut ReputationRegistry, addr: address, _ctx: &TxContext) {
        if (!table::contains(&config.user_registry, addr)) {
            table::add(&mut config.user_registry, addr, UserRecord {
                tier: 0,
                verified_cert_count: 0,
                slashed_until_epoch: 0,
            });
        }
    }

    fun get_user_tier(config: &ReputationRegistry, addr: address): u8 {
        if (!table::contains(&config.user_registry, addr)) {
            return 0
        };
        let record = table::borrow(&config.user_registry, addr);
        record.tier
    }

    fun is_slashed(config: &ReputationRegistry, addr: address, epoch: u64): bool {
        if (!table::contains(&config.user_registry, addr)) {
            return false
        };
        let record = table::borrow(&config.user_registry, addr);
        record.slashed_until_epoch > 0 && record.slashed_until_epoch >= epoch
    }

    fun promote_tier_if_eligible(
        config: &mut ReputationRegistry,
        addr: address,
        ctx: &TxContext
    ) {
        if (!table::contains(&config.user_registry, addr)) return;

        let record = table::borrow_mut(&mut config.user_registry, addr);
        let count = record.verified_cert_count;
        let old_tier = record.tier;

        if (record.slashed_until_epoch > 0 && tx_context::epoch(ctx) <= record.slashed_until_epoch) {
            return
        };

        let new_tier = if (count >= config.tier3_min_verified) { 3 }
        else if (count >= config.tier2_min_verified) { 2 }
        else if (count >= config.tier1_min_verified) { 1 }
        else { 0 };

        if (new_tier > old_tier) {
            record.tier = new_tier;
            event::emit(TierChangedEvent {
                user: addr,
                old_tier,
                new_tier,
            });
        }
    }

    // ==================== ADMIN FUNCTIONS ====================

    entry fun update_treasury(
        config: &mut ReputationRegistry,
        new_treasury: address,
        ctx: &TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == config.admin, ENotAdmin);
        config.treasury = new_treasury;
    }

    entry fun update_fee(
        config: &mut ReputationRegistry,
        new_fee: u64,
        ctx: &TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == config.admin, ENotAdmin);
        assert!(new_fee <= 100, EInvalidFee);
        config.platform_fee_percent = new_fee;
    }

    entry fun update_config_params(
        config: &mut ReputationRegistry,
        tier1_activation_fee: u64,
        tier2_levelup_fee: u64,
        vouching_fee: u64,
        tier1_min_verified: u64,
        tier2_min_verified: u64,
        tier3_min_verified: u64,
        tier2_paid_min_verified: u64,
        voucher_share_percent: u64,
        platform_share_percent: u64,
        tier_upgrade_treasury_percent: u64,
        tier_upgrade_burn_percent: u64,
        ctx: &TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == config.admin, ENotAdmin);
        assert!(voucher_share_percent + platform_share_percent <= 100, EInvalidFee);
        assert!(tier_upgrade_treasury_percent + tier_upgrade_burn_percent <= 100, EInvalidFee);

        config.tier1_activation_fee = tier1_activation_fee;
        config.tier2_levelup_fee = tier2_levelup_fee;
        config.vouching_fee = vouching_fee;
        config.tier1_min_verified = tier1_min_verified;
        config.tier2_min_verified = tier2_min_verified;
        config.tier3_min_verified = tier3_min_verified;
        config.tier2_paid_min_verified = tier2_paid_min_verified;
        config.voucher_share_percent = voucher_share_percent;
        config.platform_share_percent = platform_share_percent;
        config.tier_upgrade_treasury_percent = tier_upgrade_treasury_percent;
        config.tier_upgrade_burn_percent = tier_upgrade_burn_percent;
    }

    /// Migrate registry to new package version (admin only)
    entry fun migrate(config: &mut ReputationRegistry, admin_cap: &AdminCap) {
        assert!(object::id(admin_cap) == config.admin_cap_id, ENotAdmin);
        assert!(config.version < VERSION, ENotUpgrade);
        config.version = VERSION;
    }

    // ==================== CERTIFICATE (SOULBOUND) ====================

    /// Mint native certificate (verified at mint) - partner organization
    entry fun mint_certificate_native(
        config: &mut ReputationRegistry,
        recipient: address,
        issuer: address,
        name: vector<u8>,
        description: vector<u8>,
        _rank: vector<u8>,
        image_url: vector<u8>,
        metadata_uri: vector<u8>,
        walrus_blob_id: vector<u8>,
        encrypted_blob_id: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == issuer, ENotIssuer);

        ensure_user_registry(config, recipient, ctx);

        let cert = Certificate {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            rank: string::utf8(_rank),
            image_url: string::utf8(image_url),
            issuer,
            owner: recipient,
            awarded_at: tx_context::epoch(ctx),
            metadata_uri: string::utf8(metadata_uri),
            walrus_blob_id: string::utf8(walrus_blob_id),
            encrypted_blob_id: string::utf8(encrypted_blob_id),
        };

        let cert_id = object::uid_to_address(&cert.id);

        event::emit(CertificateMintedEvent {
            certificate_id: cert_id,
            owner: recipient,
            issuer,
            name: cert.name,
            rank: cert.rank,
            is_native: true,
        });

        transfer::transfer(cert, recipient);

        // Increment verified count and promote tier
        {
            let record = table::borrow_mut(&mut config.user_registry, recipient);
            record.verified_cert_count = record.verified_cert_count + 1;
        };
        promote_tier_if_eligible(config, recipient, ctx);
    }

    /// Mint legacy certificate (pending until vouched)
    entry fun mint_certificate_legacy(
        config: &mut ReputationRegistry,
        name: vector<u8>,
        description: vector<u8>,
        _rank: vector<u8>,
        image_url: vector<u8>,
        metadata_uri: vector<u8>,
        walrus_blob_id: vector<u8>,
        encrypted_blob_id: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);

        ensure_user_registry(config, sender, ctx);

        let cert = Certificate {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            rank: string::utf8(b"Pending"),
            image_url: string::utf8(image_url),
            issuer: sender,
            owner: sender,
            awarded_at: tx_context::epoch(ctx),
            metadata_uri: string::utf8(metadata_uri),
            walrus_blob_id: string::utf8(walrus_blob_id),
            encrypted_blob_id: string::utf8(encrypted_blob_id),
        };

        let cert_id = object::uid_to_address(&cert.id);

        event::emit(CertificateMintedEvent {
            certificate_id: cert_id,
            owner: sender,
            issuer: sender,
            name: cert.name,
            rank: cert.rank,
            is_native: false,
        });

        transfer::transfer(cert, sender);
    }

    // ==================== VOUCHING ====================

    /// Tier 2+ user vouches for a pending legacy certificate
    entry fun vouch_for_legacy_certificate(
        config: &mut ReputationRegistry,
        certificate: Certificate,
        payment: Coin<CAMP>,
        ctx: &mut TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        let voucher = tx_context::sender(ctx);
        let epoch = tx_context::epoch(ctx);

        assert!(!is_slashed(config, voucher, epoch), ESlashed);
        let voucher_tier = get_user_tier(config, voucher);
        assert!(voucher_tier >= 2, ENotVoucherTier);
        assert!(certificate.rank == string::utf8(b"Pending"), ENothPending);

        let paid = coin::value(&payment);
        assert!(paid >= config.vouching_fee, EPaymentMismatch);

        let voucher_share = (paid * config.voucher_share_percent) / 100;
        let platform_share = (paid * config.platform_share_percent) / 100;

        let voucher_coin = coin::split(&mut payment, voucher_share, ctx);
        let platform_coin = coin::split(&mut payment, platform_share, ctx);

        transfer::public_transfer(voucher_coin, voucher);
        transfer::public_transfer(platform_coin, config.treasury);
        coin::destroy_zero(payment);

        let owner = certificate.owner;
        let cert_id = object::uid_to_address(&certificate.id);

        let Certificate { id, name, description, rank: _, image_url, issuer, owner, awarded_at, metadata_uri, walrus_blob_id, encrypted_blob_id } = certificate;
        let verified_cert = Certificate {
            id,
            name,
            description,
            rank: string::utf8(b"Verified"),
            image_url,
            issuer,
            owner,
            awarded_at,
            metadata_uri,
            walrus_blob_id,
            encrypted_blob_id,
        };
        transfer::transfer(verified_cert, owner);

        event::emit(BadgeVerifiedEvent {
            certificate_id: cert_id,
            voucher,
            owner,
        });

        ensure_user_registry(config, owner, ctx);
        {
            let record = table::borrow_mut(&mut config.user_registry, owner);
            record.verified_cert_count = record.verified_cert_count + 1;
        };
        promote_tier_if_eligible(config, owner, ctx);
    }

    // ==================== TIER UPGRADES (PAID) ====================

    /// Pay to activate Tier 1 (Explorer)
    entry fun upgrade_to_tier1(
        config: &mut ReputationRegistry,
        payment: Coin<CAMP>,
        ctx: &mut TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);
        let epoch = tx_context::epoch(ctx);

        assert!(!is_slashed(config, sender, epoch), ESlashed);
        ensure_user_registry(config, sender, ctx);

        {
            let record = table::borrow_mut(&mut config.user_registry, sender);
            assert!(record.tier == 0, EAlreadyTier1);
            assert!(record.verified_cert_count >= 1, EInsufficientVerified); // min 1 for paid path
        };

        let paid = coin::value(&payment);
        assert!(paid >= config.tier1_activation_fee, EPaymentMismatch);

        let treasury_share = (paid * config.tier_upgrade_treasury_percent) / 100;

        let treasury_coin = coin::split(&mut payment, treasury_share, ctx);
        transfer::public_transfer(treasury_coin, config.treasury);
        coin::destroy_zero(payment);

        let record = table::borrow_mut(&mut config.user_registry, sender);
        record.tier = 1;
        event::emit(TierChangedEvent { user: sender, old_tier: 0, new_tier: 1 });
    }

    /// Pay to level up to Tier 2 (Veteran)
    entry fun upgrade_to_tier2(
        config: &mut ReputationRegistry,
        payment: Coin<CAMP>,
        ctx: &mut TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);
        let epoch = tx_context::epoch(ctx);

        assert!(!is_slashed(config, sender, epoch), ESlashed);
        ensure_user_registry(config, sender, ctx);

        {
            let record = table::borrow_mut(&mut config.user_registry, sender);
            assert!(record.tier == 1, ENotTier1);
            assert!(record.verified_cert_count >= config.tier2_paid_min_verified, EInsufficientVerified);
        };

        let paid = coin::value(&payment);
        assert!(paid >= config.tier2_levelup_fee, EPaymentMismatch);

        let treasury_share = (paid * config.tier_upgrade_treasury_percent) / 100;

        let treasury_coin = coin::split(&mut payment, treasury_share, ctx);
        transfer::public_transfer(treasury_coin, config.treasury);
        coin::destroy_zero(payment);

        let record = table::borrow_mut(&mut config.user_registry, sender);
        let old = record.tier;
        record.tier = 2;
        event::emit(TierChangedEvent { user: sender, old_tier: old, new_tier: 2 });
    }

    // ==================== SLASHING ====================

    entry fun slash_voucher(
        config: &mut ReputationRegistry,
        voucher_address: address,
        slashed_until_epoch: u64,
        ctx: &TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == config.admin, ENotAdmin);

        if (!table::contains(&config.user_registry, voucher_address)) return;

        let record = table::borrow_mut(&mut config.user_registry, voucher_address);
        record.tier = 0;
        record.slashed_until_epoch = slashed_until_epoch;
        event::emit(VoucherSlashedEvent { voucher: voucher_address, new_tier: 0 });
    }

    // ==================== SEAL GATE ====================

    /// Tier 2/3 recruiter requests access to decrypted certificate data (Seal reads this event)
    entry fun request_seal_access(
        config: &ReputationRegistry,
        certificate_id: address,
        ctx: &TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        let requester = tx_context::sender(ctx);
        let epoch = tx_context::epoch(ctx);

        assert!(!is_slashed(config, requester, epoch), ESlashed);
        let tier = get_user_tier(config, requester);
        assert!(tier >= 2, ENotRecruiterTier);

        event::emit(SealAccessRequestedEvent {
            certificate_id,
            requester,
            epoch,
        });
    }

    // ==================== AWARD/BADGE (TRADABLE) - Legacy compatibility ====================

    entry fun mint_badge_paid(
        config: &ReputationRegistry,
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
        assert!(config.version == VERSION, EWrongVersion);
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

    entry fun transfer_badge_with_royalty(
        config: &ReputationRegistry,
        badge: BadgeNFT,
        payment: Coin<SUI>,
        new_owner: address,
        ctx: &mut TxContext
    ) {
        assert!(config.version == VERSION, EWrongVersion);
        let sale_price = coin::value(&payment);
        let badge_id = object::uid_to_address(&badge.id);
        let original_minter = badge.original_minter;
        let from = tx_context::sender(ctx);

        let creator_royalty = (sale_price * CREATOR_ROYALTY_PERCENT) / 100;
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

    public fun get_platform_fee(config: &ReputationRegistry): u64 {
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

    public fun get_user_tier_public(config: &ReputationRegistry, addr: address): u8 {
        get_user_tier(config, addr)
    }

    public fun get_user_verified_count(config: &ReputationRegistry, addr: address): u64 {
        if (!table::contains(&config.user_registry, addr)) return 0;
        let record = table::borrow(&config.user_registry, addr);
        record.verified_cert_count
    }

    public fun get_certificate_info(cert: &Certificate): (String, String, String, address, address, u64, String, String) {
        (
            cert.name,
            cert.description,
            cert.rank,
            cert.issuer,
            cert.owner,
            cert.awarded_at,
            cert.metadata_uri,
            cert.walrus_blob_id
        )
    }

    // ==================== TESTS ====================

    #[test]
    fun test_get_badge_info() {
        let ctx = &mut tx_context::dummy();
        let sender = tx_context::sender(ctx);

        let badge = BadgeNFT {
            id: object::new(ctx),
            name: string::utf8(b"Test Badge"),
            description: string::utf8(b"Test Description"),
            rank: string::utf8(b"Gold"),
            image_url: string::utf8(b"https://example.com/badge.png"),
            issuer: sender,
            original_minter: sender,
            awarded_at: 100,
            metadata_uri: string::utf8(b"https://example.com/metadata"),
        };

        let (name, desc, rank, issuer, minter, awarded_at) = get_badge_info(&badge);
        assert!(name == string::utf8(b"Test Badge"), 0);
        assert!(desc == string::utf8(b"Test Description"), 1);
        assert!(rank == string::utf8(b"Gold"), 2);
        assert!(issuer == sender, 3);
        assert!(minter == sender, 4);
        assert!(awarded_at == 100, 5);

        transfer::public_transfer(badge, sender);
    }

    #[test]
    fun test_get_certificate_info() {
        let ctx = &mut tx_context::dummy();
        let sender = tx_context::sender(ctx);

        let cert = Certificate {
            id: object::new(ctx),
            name: string::utf8(b"LinkedIn Import"),
            description: string::utf8(b"Legacy credential"),
            rank: string::utf8(b"Pending"),
            image_url: string::utf8(b""),
            issuer: sender,
            owner: sender,
            awarded_at: 1,
            metadata_uri: string::utf8(b"walrus://blob123"),
            walrus_blob_id: string::utf8(b"blob_abc"),
            encrypted_blob_id: string::utf8(b"seal_enc_xyz"),
        };

        let (name, _desc, rank, _issuer, owner, _awarded_at, _meta_uri, blob_id) = get_certificate_info(&cert);
        assert!(name == string::utf8(b"LinkedIn Import"), 0);
        assert!(rank == string::utf8(b"Pending"), 1);
        assert!(owner == sender, 2);
        assert!(blob_id == string::utf8(b"blob_abc"), 3);

        let Certificate { id, name: _, description: _, rank: _, image_url: _, issuer: _, owner: _, awarded_at: _, metadata_uri: _, walrus_blob_id: _, encrypted_blob_id: _ } = cert;
        object::delete(id);
    }
}
