// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Utility functions for time-locked balance.
module stardust::timelocked_balance {

    use sui::balance::Balance;

    use stardust::timelock::{Self, TimeLock};

    /// For when trying to split a timelocked balance with a value that is equal to or larger than the original locked value.
    const ENotEnoughToSplit: u64 = 0;
    /// For when there is an attempt to extract a zero value from a time-locked balance.
    const EZeroValueSubBalance: u64 = 1;
    /// For when trying to join two timelocks with different expiration time.
    const EDifferentExpirationTime: u64 = 2;

    /// Join two `TimeLock<Balance<T>>` together.
    public fun join<T>(self: &mut TimeLock<Balance<T>>, other: TimeLock<Balance<T>>) {
        // Check the preconditions.
        assert!(self.expiration_timestamp_ms() == other.expiration_timestamp_ms(), EDifferentExpirationTime);

        // Unpack the time-locked balance.
        let (value, _) = timelock::unpack(other);

        // Join the balances.
        self.locked_mut().join(value);
    }

    /// Join everything in `others` with `self`.
    public fun join_vec<T>(self: &mut TimeLock<Balance<T>>, mut others: vector<TimeLock<Balance<T>>>) {
        // Create useful variables.
        let (mut i, len) = (0, others.length());

        // Join all the balances.
        while (i < len) {
            let other = others.pop_back();
            Self::join(self, other);
            i = i + 1
        };

        // Destroy the empty vector.
        vector::destroy_empty(others)
    }

    /// Split a `TimeLock<Balance<T>>` and take a sub balance from it.
    public fun split<T>(self: &mut TimeLock<Balance<T>>, value: u64, ctx: &mut TxContext): TimeLock<Balance<T>> {
        // Check the preconditions.
        assert!(value > 0, EZeroValueSubBalance);
        assert!(self.locked().value() > value, ENotEnoughToSplit);

        // Split the locked balance.
        let value = self.locked_mut().split(value);

        // Pack the splitted balance into a timelock.
        timelock::pack(value, self.expiration_timestamp_ms(), ctx)
    }
}
