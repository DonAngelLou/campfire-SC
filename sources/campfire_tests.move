/// Unit tests for Campfire Badge module
#[test_only]
module campfire::campfire_tests {

    use campfire::CampfireBadge;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::string;

    #[test]
    fun test_get_badge_info() {
        let ctx = &mut tx_context::dummy();
        let sender = tx_context::sender(ctx);

        let badge = CampfireBadge::BadgeNFT {
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

        let (name, desc, rank, issuer, minter, awarded_at) = CampfireBadge::get_badge_info(&badge);
        assert!(name == string::utf8(b"Test Badge"), 0);
        assert!(desc == string::utf8(b"Test Description"), 1);
        assert!(rank == string::utf8(b"Gold"), 2);
        assert!(issuer == sender, 3);
        assert!(minter == sender, 4);
        assert!(awarded_at == 100, 5);

        transfer::public_transfer(badge, sender);
    }

    #[test]
    fun test_get_badge_name_rank_issuer() {
        let ctx = &mut tx_context::dummy();
        let sender = tx_context::sender(ctx);

        let badge = CampfireBadge::BadgeNFT {
            id: object::new(ctx),
            name: string::utf8(b"SUI Move Expert"),
            description: string::utf8(b"Advanced Move developer"),
            rank: string::utf8(b"Verified"),
            image_url: string::utf8(b""),
            issuer: @0x123,
            original_minter: sender,
            awarded_at: 42,
            metadata_uri: string::utf8(b""),
        };

        assert!(CampfireBadge::get_badge_name(&badge) == string::utf8(b"SUI Move Expert"), 0);
        assert!(CampfireBadge::get_badge_rank(&badge) == string::utf8(b"Verified"), 1);
        assert!(CampfireBadge::get_badge_issuer(&badge) == @0x123, 2);
        assert!(CampfireBadge::get_badge_original_minter(&badge) == sender, 3);

        transfer::public_transfer(badge, sender);
    }

    #[test]
    fun test_certificate_info() {
        let ctx = &mut tx_context::dummy();
        let sender = tx_context::sender(ctx);

        let cert = CampfireBadge::Certificate {
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

        let (name, desc, rank, issuer, owner, awarded_at, meta_uri, blob_id) =
            CampfireBadge::get_certificate_info(&cert);
        assert!(name == string::utf8(b"LinkedIn Import"), 0);
        assert!(rank == string::utf8(b"Pending"), 1);
        assert!(owner == sender, 2);
        assert!(blob_id == string::utf8(b"blob_abc"), 3);

        let CampfireBadge::Certificate { id, name: _, description: _, rank: _, image_url: _,
            issuer: _, owner: _, awarded_at: _, metadata_uri: _, walrus_blob_id: _,
            encrypted_blob_id: _ } = cert;
        object::delete(id);
    }
}
