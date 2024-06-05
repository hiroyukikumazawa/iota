// Copyright (c) 2024 IOTA Stiftung
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module timelock::timelocked_stake_tests {

    use sui::balance;
    use sui::balance::Balance;
    use sui::coin::Coin;
    use sui::sui::SUI;
    use sui::table::Table;
    use sui::test_scenario::{Self, Scenario};
    use sui::test_utils::assert_eq;
    use sui::test_utils;

    use sui_system::sui_system::SuiSystemState;
    use sui_system::staking_pool::{Self, PoolTokenExchangeRate};
    use sui_system::validator_set::{Self, ValidatorSet};
    use sui_system::governance_test_utils::{
        add_validator,
        add_validator_candidate,
        advance_epoch,
        advance_epoch_with_reward_amounts,
        assert_validator_total_stake_amounts,
        create_validator_for_testing,
        create_sui_system_state_for_testing,
        remove_validator,
        remove_validator_candidate,
        total_sui_balance,
        unstake,
    };

    use timelock::label::LabelerCap;
    use timelock::timelock::{Self, TimeLock};
    use timelock::timelocked_staked_sui::{Self, TimelockedStakedSui};
    use timelock::timelocked_staking;

    use timelock::test_label_one::{Self, TEST_LABEL_ONE};
    use timelock::test_label_two::{Self, TEST_LABEL_TWO};

    const VALIDATOR_ADDR_1: address = @0x1;
    const VALIDATOR_ADDR_2: address = @0x2;

    const STAKER_ADDR_1: address = @0x42;
    const STAKER_ADDR_2: address = @0x43;
    const STAKER_ADDR_3: address = @0x44;

    const NEW_VALIDATOR_ADDR: address = @0x1a4623343cd42be47d67314fce0ad042f3c82685544bc91d8c11d24e74ba7357;
    // Generated with seed [0;32]
    const NEW_VALIDATOR_PUBKEY: vector<u8> = x"99f25ef61f8032b914636460982c5cc6f134ef1ddae76657f2cbfec1ebfc8d097374080df6fcf0dcb8bc4b0d8e0af5d80ebbff2b4c599f54f42d6312dfc314276078c1cc347ebbbec5198be258513f386b930d02c2749a803e2330955ebd1a10";
    // Generated using [fn test_proof_of_possession]
    const NEW_VALIDATOR_POP: vector<u8> = x"8b93fc1b33379e2796d361c4056f0f04ad5aea7f4a8c02eaac57340ff09b6dc158eb1945eece103319167f420daf0cb3";

    const MIST_PER_SUI: u64 = 1_000_000_000;

    #[test]
    fun test_split_join_staked_sui() {
        // All this is just to generate a dummy StakedSui object to split and join later
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            let ctx = scenario.ctx();
            staked_sui.split_to_sender(20 * MIST_PER_SUI, ctx);
            scenario.return_to_sender(staked_sui);
        };

        // Verify the correctness of the split and send the join txn
        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();
            assert!(staked_sui_ids.length() == 2, 101); // staked sui split to 2 coins

            let mut part1 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[0]);
            let part2 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[1]);

            let amount1 = part1.amount();
            let amount2 = part2.amount();
            assert!(amount1 == 20 * MIST_PER_SUI || amount1 == 40 * MIST_PER_SUI, 102);
            assert!(amount2 == 20 * MIST_PER_SUI || amount2 == 40 * MIST_PER_SUI, 103);
            assert!(amount1 + amount2 == 60 * MIST_PER_SUI, 104);

            part1.join(part2);
            assert!(part1.amount() == 60 * MIST_PER_SUI, 105);
            scenario.return_to_sender(part1);
        };
        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = timelocked_staked_sui::EIncompatibleTimelockedStakedSui)]
    fun test_join_different_epochs() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;
        // Create two instances of staked sui w/ different epoch activations
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);
        advance_epoch(scenario);
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);

        // Verify that these cannot be merged
        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();
            let mut part1 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[0]);
            let part2 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[1]);

            part1.join(part2);

            scenario.return_to_sender(part1);
        };
        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = timelocked_staked_sui::EIncompatibleTimelockedStakedSui)]
    fun test_join_different_timestamps() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;
        // Create two instances of staked sui w/ different epoch activations
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 20, scenario);

        // Verify that these cannot be merged
        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();
            let mut part1 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[0]);
            let part2 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[1]);

            part1.join(part2);

            scenario.return_to_sender(part1);
        };
        scenario_val.end();
    }

    #[test]
    fun test_join_same_labels() {
        set_up_sui_system_state();

        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;

        set_up_timelock_labeler_caps(STAKER_ADDR_1, scenario);

        // Create two instances of labeled staked sui w/ different epoch activations
        scenario.next_tx(STAKER_ADDR_1);
        {
            let labeler_one = scenario.take_from_sender<LabelerCap<TEST_LABEL_ONE>>();

            stake_labeled_timelocked_with(&labeler_one, STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);
            stake_labeled_timelocked_with(&labeler_one, STAKER_ADDR_1, VALIDATOR_ADDR_1, 50, 10, scenario);

            scenario.return_to_sender(labeler_one);
        };

        // Verify that these can be merged
        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();
            let mut part1 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[0]);
            let part2 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[1]);

            part1.join(part2);

            assert_eq(part1.staked_sui_amount(), 110 * MIST_PER_SUI);
            assert_eq(part1.expiration_timestamp_ms(), 10);
            assert_eq(part1.label().borrow().is_type<TEST_LABEL_ONE>(), true);

            scenario.return_to_sender(part1);
        };
        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = timelocked_staked_sui::EIncompatibleTimelockedStakedSui)]
    fun test_join_different_labels() {
        set_up_sui_system_state();

        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;

        set_up_timelock_labeler_caps(STAKER_ADDR_1, scenario);

        // Create two instances of labeled staked sui w/ different epoch activations
        scenario.next_tx(STAKER_ADDR_1);
        {
            let labeler_one = scenario.take_from_sender<LabelerCap<TEST_LABEL_ONE>>();
            let labeler_two = scenario.take_from_sender<LabelerCap<TEST_LABEL_TWO>>();

            stake_labeled_timelocked_with(&labeler_one, STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);
            advance_epoch(scenario);
            stake_labeled_timelocked_with(&labeler_two, STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);

            scenario.return_to_sender(labeler_one);
            scenario.return_to_sender(labeler_two);
        };

        // Verify that these cannot be merged
        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();
            let mut part1 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[0]);
            let part2 = scenario.take_from_sender_by_id<TimelockedStakedSui>(staked_sui_ids[1]);

            part1.join(part2);

            scenario.return_to_sender(part1);
        };
        scenario_val.end();
    }

    #[test]
    fun test_split_with_labels() {
        set_up_sui_system_state();

        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;

        set_up_timelock_labeler_caps(STAKER_ADDR_1, scenario);

        // Create two instances of labeled staked sui w/ different epoch activations
        scenario.next_tx(STAKER_ADDR_1);
        {
            let labeler_one = scenario.take_from_sender<LabelerCap<TEST_LABEL_ONE>>();

            stake_labeled_timelocked_with(&labeler_one, STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);

            scenario.return_to_sender(labeler_one);

            advance_epoch(scenario);
        };

        // Verify that these can be splitted
        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut original = scenario.take_from_sender<TimelockedStakedSui>();
            let splitted = original.split(20 * MIST_PER_SUI, scenario.ctx());

            assert_eq(original.staked_sui_amount(), 40 * MIST_PER_SUI);
            assert_eq(original.expiration_timestamp_ms(), 10);
            assert_eq(original.label().borrow().is_type<TEST_LABEL_ONE>(), true);

            assert_eq(splitted.staked_sui_amount(), 20 * MIST_PER_SUI);
            assert_eq(splitted.expiration_timestamp_ms(), 10);
            assert_eq(splitted.label().borrow().is_type<TEST_LABEL_ONE>(), true);

            scenario.return_to_sender(original);
            test_utils::destroy(splitted);
        };
        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = staking_pool::EStakedSuiBelowThreshold)]
    fun test_split_below_threshold() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;
        // Stake 2 SUI
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 2, 10, scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            let ctx = scenario.ctx();
            // The remaining amount after splitting is below the threshold so this should fail.
            staked_sui.split_to_sender(1 * MIST_PER_SUI + 1, ctx);
            scenario.return_to_sender(staked_sui);
        };
        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = staking_pool::EStakedSuiBelowThreshold)]
    fun test_split_nonentry_below_threshold() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(STAKER_ADDR_1);
        let scenario = &mut scenario_val;
        // Stake 2 SUI
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 2, 10, scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            let ctx = scenario.ctx();
            // The remaining amount after splitting is below the threshold so this should fail.
            let stake = staked_sui.split(1 * MIST_PER_SUI + 1, ctx);
            test_utils::destroy(stake);
            scenario.return_to_sender(staked_sui);
        };
        scenario_val.end();
    }

    #[test]
    fun test_add_remove_stake_flow() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            let ctx = scenario.ctx();

            // Create a stake to VALIDATOR_ADDR_1.
            timelocked_staking::request_add_stake(
                system_state_mut_ref,
                timelock::lock(balance::create_for_testing(60 * MIST_PER_SUI), 10, ctx),
                VALIDATOR_ADDR_1,
                ctx
            );

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 100 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            test_scenario::return_shared(system_state);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            assert_eq(staked_sui.amount(), 60 * MIST_PER_SUI);

            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 160 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            let ctx = scenario.ctx();

            // Unstake from VALIDATOR_ADDR_1
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui, ctx);

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 160 * MIST_PER_SUI);
            test_scenario::return_shared(system_state);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            assert_eq(system_state.validator_stake_amount(VALIDATOR_ADDR_1), 100 * MIST_PER_SUI);
            test_scenario::return_shared(system_state);
        };
        scenario_val.end();
    }

    #[test]
    fun test_add_remove_labeled_stake_flow() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        set_up_timelock_labeler_caps(STAKER_ADDR_1, scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let labeler_one = scenario.take_from_sender<LabelerCap<TEST_LABEL_ONE>>();

            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            let ctx = scenario.ctx();

            // Create a stake to VALIDATOR_ADDR_1.
            timelocked_staking::request_add_stake(
                system_state_mut_ref,
                timelock::lock_with_label(&labeler_one, balance::create_for_testing(60 * MIST_PER_SUI), 10, ctx),
                VALIDATOR_ADDR_1,
                ctx
            );

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 100 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            test_scenario::return_shared(system_state);

            scenario.return_to_sender(labeler_one);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            assert_eq(staked_sui.amount(), 60 * MIST_PER_SUI);

            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 160 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            // Unstake from VALIDATOR_ADDR_1
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui, scenario.ctx());

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 160 * MIST_PER_SUI);
            test_scenario::return_shared(system_state);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();

            assert_eq(system_state.validator_stake_amount(VALIDATOR_ADDR_1), 100 * MIST_PER_SUI);

            // Check the time-locked balance.
            let timelock = scenario.take_from_sender<TimeLock<Balance<SUI>>>();

            assert_eq(timelock.locked().value(), 60 * MIST_PER_SUI);
            assert_eq(timelock.expiration_timestamp_ms(), 10);
            assert_eq(timelock.label().borrow().is_type<TEST_LABEL_ONE>(), true);

            scenario.return_to_sender(timelock);

            test_scenario::return_shared(system_state);
        };
        scenario_val.end();
    }

    #[test]
    fun test_add_remove_stake_mul_bal_flow() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            let ctx = scenario.ctx();

            let mut balances = vector[];

            balances.push_back(timelock::lock(balance::create_for_testing(30 * MIST_PER_SUI), 10, ctx));
            balances.push_back(timelock::lock(balance::create_for_testing(60 * MIST_PER_SUI), 20, ctx));

            // Create a stake to VALIDATOR_ADDR_1.
            timelocked_staking::request_add_stake_mul_bal(
                system_state_mut_ref,
                balances,
                VALIDATOR_ADDR_1,
                ctx
            );

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 100 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            test_scenario::return_shared(system_state);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let stake_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();

            let staked_sui1 = scenario.take_from_sender_by_id<TimelockedStakedSui>(stake_sui_ids[0]);
            assert_eq(staked_sui1.amount(), 30 * MIST_PER_SUI);
            let staked_sui2 = scenario.take_from_sender_by_id<TimelockedStakedSui>(stake_sui_ids[1]);
            assert_eq(staked_sui2.amount(), 60 * MIST_PER_SUI);

            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 190 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            let ctx = scenario.ctx();

            // First unstake from VALIDATOR_ADDR_1
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui1, ctx);

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 190 * MIST_PER_SUI);

            scenario.return_to_sender(staked_sui2);
            test_scenario::return_shared(system_state);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            let staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            assert_eq(staked_sui.amount(), 60 * MIST_PER_SUI);

            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 160 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            let ctx = scenario.ctx();

            // Second unstake from VALIDATOR_ADDR_1
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui, ctx);

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 160 * MIST_PER_SUI);
            test_scenario::return_shared(system_state);
        };

        advance_epoch(scenario);

        scenario.next_tx(STAKER_ADDR_1);
        {
            assert_eq(scenario.has_most_recent_for_sender<TimelockedStakedSui>(), false);

            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_1), 100 * MIST_PER_SUI);
            assert_eq(system_state_mut_ref.validator_stake_amount(VALIDATOR_ADDR_2), 100 * MIST_PER_SUI);

            test_scenario::return_shared(system_state);
        };

        scenario_val.end();
    }

    #[test]
    fun test_remove_stake_post_active_flow_no_rewards() {
        set_up_sui_system_state_with_storage_fund();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 100, 10, scenario);

        advance_epoch(scenario);

        assert_validator_total_stake_amounts(
            vector[VALIDATOR_ADDR_1, VALIDATOR_ADDR_2],
            vector[200 * MIST_PER_SUI, 100 * MIST_PER_SUI],
            scenario
        );

        advance_epoch(scenario);

        remove_validator(VALIDATOR_ADDR_1, scenario);

        advance_epoch(scenario);

        // Make sure stake withdrawal happens
        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert!(!is_active_validator_by_sui_address(system_state_mut_ref.validators(), VALIDATOR_ADDR_1), 0);

            let staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            assert_eq(staked_sui.amount(), 100 * MIST_PER_SUI);

            // Unstake from VALIDATOR_ADDR_1
            assert!(!has_sui_coins(STAKER_ADDR_1, scenario), 1);
            let ctx = scenario.ctx();
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui, ctx);

            // Make sure they have all of their stake.
            assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);
            assert!(!has_sui_coins(STAKER_ADDR_1, scenario), 2);

            test_scenario::return_shared(system_state);
        };

        // Validator unstakes now.
        assert!(!has_sui_coins(VALIDATOR_ADDR_1, scenario), 3);
        unstake(VALIDATOR_ADDR_1, 0, scenario);

        // Make sure have all of their stake. NB there is no epoch change. This is immediate.
        assert_eq(total_sui_balance(VALIDATOR_ADDR_1, scenario), 100 * MIST_PER_SUI);

        scenario_val.end();
    }

    #[test]
    fun test_remove_stake_post_active_flow_with_rewards() {
        set_up_sui_system_state_with_storage_fund();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 100, 10, scenario);

        advance_epoch(scenario);

        assert_validator_total_stake_amounts(
            vector[VALIDATOR_ADDR_1, VALIDATOR_ADDR_2],
            vector[200 * MIST_PER_SUI, 100 * MIST_PER_SUI],
            scenario
        );

        // Each validator pool gets 30 MIST and each validator gets an additional 10 MIST.
        advance_epoch_with_reward_amounts(0, 80, scenario);

        remove_validator(VALIDATOR_ADDR_1, scenario);

        advance_epoch(scenario);

        let reward_amt = 15 * MIST_PER_SUI;
        let validator_reward_amt = 10 * MIST_PER_SUI;

        // Make sure stake withdrawal happens
        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert!(!is_active_validator_by_sui_address(system_state_mut_ref.validators(), VALIDATOR_ADDR_1), 0);

            let staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            assert_eq(staked_sui.amount(), 100 * MIST_PER_SUI);

            // Unstake from VALIDATOR_ADDR_1
            assert!(!has_sui_coins(STAKER_ADDR_1, scenario), 1);
            let ctx = scenario.ctx();
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui, ctx);

            // Make sure they have all of their stake.
            assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);
            assert_eq(total_sui_balance(STAKER_ADDR_1, scenario), reward_amt);

            test_scenario::return_shared(system_state);
        };

        // Validator unstakes now.
        assert!(!has_sui_coins(VALIDATOR_ADDR_1, scenario), 2);
        unstake(VALIDATOR_ADDR_1, 0, scenario);
        unstake(VALIDATOR_ADDR_1, 0, scenario);

        // Make sure have all of their stake. NB there is no epoch change. This is immediate.
        assert_eq(total_sui_balance(VALIDATOR_ADDR_1, scenario), 100 * MIST_PER_SUI + reward_amt + validator_reward_amt);

        scenario_val.end();
    }

    #[test]
    fun test_earns_rewards_at_last_epoch() {
        set_up_sui_system_state_with_storage_fund();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 100, 10, scenario);

        advance_epoch(scenario);

        remove_validator(VALIDATOR_ADDR_1, scenario);

        // Add some rewards after the validator requests to leave. Since the validator is still active
        // this epoch, they should get the rewards from this epoch.
        advance_epoch_with_reward_amounts(0, 80, scenario);

        // Each validator pool gets 30 MIST and validators shares the 20 MIST from the storage fund
        // so validator gets another 10 MIST.
        let reward_amt = 15 * MIST_PER_SUI;
        let validator_reward_amt = 10 * MIST_PER_SUI;

        // Make sure stake withdrawal happens
        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            let staked_sui = scenario.take_from_sender<TimelockedStakedSui>();
            assert_eq(staked_sui.amount(), 100 * MIST_PER_SUI);

            // Unstake from VALIDATOR_ADDR_1
            assert!(!has_timelocked_sui_balance(STAKER_ADDR_1, scenario), 0);
            assert!(!has_sui_coins(STAKER_ADDR_1, scenario), 1);
            let ctx = scenario.ctx();
            timelocked_staking::request_withdraw_stake(system_state_mut_ref, staked_sui, ctx);

            // Make sure they have all of their stake.
            assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);
            assert_eq(total_sui_balance(STAKER_ADDR_1, scenario), reward_amt);

            test_scenario::return_shared(system_state);
        };

        // Validator unstakes now.
        assert!(!has_sui_coins(VALIDATOR_ADDR_1, scenario), 2);
        unstake(VALIDATOR_ADDR_1, 0, scenario);
        unstake(VALIDATOR_ADDR_1, 0, scenario);

        // Make sure have all of their stake. NB there is no epoch change. This is immediate.
        assert_eq(total_sui_balance(VALIDATOR_ADDR_1, scenario), 100 * MIST_PER_SUI + reward_amt + validator_reward_amt);

        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = validator_set::ENotAValidator)]
    fun test_add_stake_post_active_flow() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 100, 10, scenario);

        advance_epoch(scenario);

        remove_validator(VALIDATOR_ADDR_1, scenario);

        advance_epoch(scenario);

        // Make sure the validator is no longer active.
        scenario.next_tx(STAKER_ADDR_1);
        {
            let mut system_state = scenario.take_shared<SuiSystemState>();
            let system_state_mut_ref = &mut system_state;

            assert!(!is_active_validator_by_sui_address(system_state_mut_ref.validators(), VALIDATOR_ADDR_1), 0);

            test_scenario::return_shared(system_state);
        };

        // Now try and stake to the old validator/staking pool. This should fail!
        stake_timelocked_with(STAKER_ADDR_1, VALIDATOR_ADDR_1, 60, 10, scenario);

        scenario_val.end();
    }

    #[test]
    fun test_add_preactive_remove_preactive() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        add_validator_candidate(NEW_VALIDATOR_ADDR, b"name5", b"/ip4/127.0.0.1/udp/85", NEW_VALIDATOR_PUBKEY, NEW_VALIDATOR_POP, scenario);

        // Delegate 100 MIST to the preactive validator
        stake_timelocked_with(STAKER_ADDR_1, NEW_VALIDATOR_ADDR, 100, 10, scenario);

        // Advance epoch twice with some rewards
        advance_epoch_with_reward_amounts(0, 400, scenario);
        advance_epoch_with_reward_amounts(0, 900, scenario);

        // Unstake from the preactive validator. There should be no rewards earned.
        unstake_timelocked(STAKER_ADDR_1, 0, scenario);
        assert!(!has_sui_coins(STAKER_ADDR_1, scenario), 0);
        assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);

        scenario_val.end();
    }

    #[test]
    #[expected_failure(abort_code = validator_set::ENotAValidator)]
    fun test_add_preactive_remove_pending_failure() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        add_validator_candidate(NEW_VALIDATOR_ADDR, b"name4", b"/ip4/127.0.0.1/udp/84", NEW_VALIDATOR_PUBKEY, NEW_VALIDATOR_POP, scenario);

        add_validator(NEW_VALIDATOR_ADDR, scenario);

        // Delegate 100 SUI to the pending validator. This should fail because pending active validators don't accept
        // new stakes or withdraws.
        stake_timelocked_with(STAKER_ADDR_1, NEW_VALIDATOR_ADDR, 100, 10, scenario);

        scenario_val.end();
    }

    #[test]
    fun test_add_preactive_remove_active() {
        set_up_sui_system_state_with_storage_fund();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        add_validator_candidate(NEW_VALIDATOR_ADDR, b"name3", b"/ip4/127.0.0.1/udp/83", NEW_VALIDATOR_PUBKEY, NEW_VALIDATOR_POP, scenario);

        // Delegate 100 SUI to the preactive validator
        stake_timelocked_with(STAKER_ADDR_1, NEW_VALIDATOR_ADDR, 100, 10, scenario);
        advance_epoch_with_reward_amounts(0, 300, scenario);
        // At this point we got the following distribution of stake:
        // V1: 250, V2: 250, storage fund: 100

        stake_timelocked_with(STAKER_ADDR_2, NEW_VALIDATOR_ADDR, 50, 10, scenario);
        stake_timelocked_with(STAKER_ADDR_3, NEW_VALIDATOR_ADDR, 100, 10, scenario);

        // Now the preactive becomes active
        add_validator(NEW_VALIDATOR_ADDR, scenario);
        advance_epoch(scenario);

        // At this point we got the following distribution of stake:
        // V1: 250, V2: 250, V3: 250, storage fund: 100

        advance_epoch_with_reward_amounts(0, 85, scenario);

        // staker 1 and 3 unstake from the validator and earns about 2/5 * (85 - 10) * 1/3 = 10 SUI each.
        // Although they stake in different epochs, they earn the same rewards as long as they unstake
        // in the same epoch because the validator was preactive when they staked.
        // So they will both get slightly more than 110 SUI in total balance.
        unstake_timelocked(STAKER_ADDR_1, 0, scenario);
        assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);
        assert_eq(total_sui_balance(STAKER_ADDR_1, scenario), 10_002_000_000);

        unstake_timelocked(STAKER_ADDR_3, 0, scenario);
        assert_eq(total_timelocked_sui_balance(STAKER_ADDR_3, scenario), 100 * MIST_PER_SUI);
        assert_eq(total_sui_balance(STAKER_ADDR_3, scenario), 10_002_000_000);

        advance_epoch_with_reward_amounts(0, 85, scenario);

        unstake_timelocked(STAKER_ADDR_2, 0, scenario);
        // staker 2 earns about 5 SUI from the previous epoch and 24-ish from this one
        // so in total she has about 50 + 5 + 24 = 79 SUI.
        assert_eq(total_timelocked_sui_balance(STAKER_ADDR_2, scenario), 50 * MIST_PER_SUI);
        assert_eq(total_sui_balance(STAKER_ADDR_2, scenario), 28_862_939_078);

        scenario_val.end();
    }

    #[test]
    fun test_add_preactive_remove_post_active() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        add_validator_candidate(NEW_VALIDATOR_ADDR, b"name1", b"/ip4/127.0.0.1/udp/81", NEW_VALIDATOR_PUBKEY, NEW_VALIDATOR_POP, scenario);

        // Delegate 100 SUI to the preactive validator
        stake_timelocked_with(STAKER_ADDR_1, NEW_VALIDATOR_ADDR, 100, 10, scenario);

        // Now the preactive becomes active
        add_validator(NEW_VALIDATOR_ADDR, scenario);
        advance_epoch(scenario);

        // staker 1 earns a bit greater than 30 SUI here. A bit greater because the new validator's voting power
        // is slightly greater than 1/3 of the total voting power.
        advance_epoch_with_reward_amounts(0, 90, scenario);

        // And now the validator leaves the validator set.
        remove_validator(NEW_VALIDATOR_ADDR, scenario);

        advance_epoch(scenario);

        unstake_timelocked(STAKER_ADDR_1, 0, scenario);
        assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);
        assert_eq(total_sui_balance(STAKER_ADDR_1, scenario), 30_006_000_000);

        scenario_val.end();
    }

    #[test]
    fun test_add_preactive_candidate_drop_out() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(VALIDATOR_ADDR_1);
        let scenario = &mut scenario_val;

        add_validator_candidate(NEW_VALIDATOR_ADDR, b"name2", b"/ip4/127.0.0.1/udp/82", NEW_VALIDATOR_PUBKEY, NEW_VALIDATOR_POP, scenario);

        // Delegate 100 MIST to the preactive validator
        stake_timelocked_with(STAKER_ADDR_1, NEW_VALIDATOR_ADDR, 100, 10, scenario);

        // Advance epoch and give out some rewards. The candidate should get nothing, of course.
        advance_epoch_with_reward_amounts(0, 800, scenario);

        // Now the candidate leaves.
        remove_validator_candidate(NEW_VALIDATOR_ADDR, scenario);

        // Advance epoch a few times.
        advance_epoch(scenario);
        advance_epoch(scenario);
        advance_epoch(scenario);

        // Unstake now and the staker should get no rewards.
        unstake_timelocked(STAKER_ADDR_1, 0, scenario);
        assert_eq(total_timelocked_sui_balance(STAKER_ADDR_1, scenario), 100 * MIST_PER_SUI);
        assert!(!has_sui_coins(STAKER_ADDR_1, scenario), 0);

        scenario_val.end();
    }

    #[test]
    fun test_staking_pool_exchange_rate_getter() {
        set_up_sui_system_state();
        let mut scenario_val = test_scenario::begin(@0x0);
        let scenario = &mut scenario_val;
        stake_timelocked_with(@0x42, @0x2, 100, 10, scenario); // stakes 100 SUI with 0x2
        scenario.next_tx(@0x42);
        let staked_sui = scenario.take_from_address<TimelockedStakedSui>(@0x42);
        let pool_id = staked_sui.pool_id();
        test_scenario::return_to_address(@0x42, staked_sui);
        advance_epoch(scenario); // advances epoch to effectuate the stake
        // Each staking pool gets 10 SUI of rewards.
        advance_epoch_with_reward_amounts(0, 20, scenario);
        let mut system_state = scenario.take_shared<SuiSystemState>();
        let rates = system_state.pool_exchange_rates(&pool_id);
        assert_eq(rates.length(), 3);
        assert_exchange_rate_eq(rates, 0, 0, 0);     // no tokens at epoch 0
        assert_exchange_rate_eq(rates, 1, 200, 200); // 200 SUI of self + delegate stake at epoch 1
        assert_exchange_rate_eq(rates, 2, 210, 200); // 10 SUI of rewards at epoch 2
        test_scenario::return_shared(system_state);
        scenario_val.end();
    }

    fun assert_exchange_rate_eq(
        rates: &Table<u64, PoolTokenExchangeRate>, epoch: u64, sui_amount: u64, pool_token_amount: u64
    ) {
        let rate = &rates[epoch];
        assert_eq(rate.sui_amount(), sui_amount * MIST_PER_SUI);
        assert_eq(rate.pool_token_amount(), pool_token_amount * MIST_PER_SUI);
    }

    fun set_up_sui_system_state() {
        let mut scenario_val = test_scenario::begin(@0x0);
        let scenario = &mut scenario_val;
        let ctx = scenario.ctx();

        let validators = vector[
            create_validator_for_testing(VALIDATOR_ADDR_1, 100, ctx),
            create_validator_for_testing(VALIDATOR_ADDR_2, 100, ctx)
        ];
        create_sui_system_state_for_testing(validators, 0, 0, ctx);
        scenario_val.end();
    }

    fun set_up_timelock_labeler_caps(to: address, scenario: &mut Scenario) {
        scenario.next_tx(to);

        test_label_one::assign_labeler_cap(to, scenario.ctx());
        test_label_two::assign_labeler_cap(to, scenario.ctx());
    }

    fun set_up_sui_system_state_with_storage_fund() {
        let mut scenario_val = test_scenario::begin(@0x0);
        let scenario = &mut scenario_val;
        let ctx = scenario.ctx();

        let validators = vector[
            create_validator_for_testing(VALIDATOR_ADDR_1, 100, ctx),
            create_validator_for_testing(VALIDATOR_ADDR_2, 100, ctx)
        ];
        create_sui_system_state_for_testing(validators, 300, 100, ctx);
        scenario_val.end();
    }

    fun stake_timelocked_with(
        staker: address,
        validator: address,
        amount: u64,
        expiration_timestamp_ms: u64,
        scenario: &mut Scenario
    ) {
        scenario.next_tx(staker);
        let mut system_state = scenario.take_shared<SuiSystemState>();

        let ctx = scenario.ctx();

        timelocked_staking::request_add_stake(
            &mut system_state,
            timelock::lock(balance::create_for_testing(amount * MIST_PER_SUI), expiration_timestamp_ms, ctx),
            validator,
            ctx);
        test_scenario::return_shared(system_state);
    }

    fun stake_labeled_timelocked_with<L>(
        cap: &LabelerCap<L>,
        staker: address,
        validator: address,
        amount: u64,
        expiration_timestamp_ms: u64,
        scenario: &mut Scenario
    ) {
        scenario.next_tx(staker);

        let mut system_state = scenario.take_shared<SuiSystemState>();
        let ctx = scenario.ctx();

        timelocked_staking::request_add_stake(
            &mut system_state,
            timelock::lock_with_label(
                cap,
                balance::create_for_testing(amount * MIST_PER_SUI),
                expiration_timestamp_ms,
                ctx),
            validator,
            ctx);

        test_scenario::return_shared(system_state);
    }

    fun unstake_timelocked(
        staker: address, staked_sui_idx: u64, scenario: &mut Scenario
    ) {
        scenario.next_tx(staker);
        let stake_sui_ids = scenario.ids_for_sender<TimelockedStakedSui>();
        let staked_sui = scenario.take_from_sender_by_id(stake_sui_ids[staked_sui_idx]);
        let mut system_state = scenario.take_shared<SuiSystemState>();

        let ctx = scenario.ctx();
        timelocked_staking::request_withdraw_stake(&mut system_state, staked_sui, ctx);
        test_scenario::return_shared(system_state);
    }


    fun total_timelocked_sui_balance(addr: address, scenario: &mut Scenario): u64 {
        let mut sum = 0;
        scenario.next_tx(addr);
        let lock_ids = scenario.ids_for_sender<TimeLock<Balance<SUI>>>();
        let mut i = 0;
        while (i < lock_ids.length()) {
            let coin = scenario.take_from_sender_by_id<TimeLock<Balance<SUI>>>(lock_ids[i]);
            sum = sum + coin.locked().value();
            scenario.return_to_sender(coin);
            i = i + 1;
        };
        sum
    }

    fun has_timelocked_sui_balance(addr: address, scenario: &mut Scenario): bool {
        scenario.next_tx(addr);
        scenario.has_most_recent_for_sender<TimeLock<Balance<SUI>>>()
    }

    fun has_sui_coins(addr: address, scenario: &mut Scenario): bool {
        scenario.next_tx(addr);
        scenario.has_most_recent_for_sender<Coin<SUI>>()
    }

    fun is_active_validator_by_sui_address(set: &ValidatorSet, validator_address: address): bool {
        let validators = set.active_validators();
        let length = validators.length();
        let mut i = 0;
        while (i < length) {
            let v = &validators[i];
            if (v.sui_address() == validator_address) {
                return true
            };
            i = i + 1;
        };
        false
    }

}
