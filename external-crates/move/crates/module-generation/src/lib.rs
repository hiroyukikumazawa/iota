// Copyright (c) The Diem Core Contributors
// Copyright (c) The Move Contributors
// Modifications Copyright (c) 2024 IOTA Stiftung
// SPDX-License-Identifier: Apache-2.0

mod generator;
mod options;
mod padding;
mod utils;

pub use generator::{
    generate_module, generate_modules, generate_verified_modules, ModuleGenerator,
};
pub use options::ModuleGeneratorOptions;
pub use padding::Pad;
