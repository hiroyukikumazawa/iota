// Copyright (c) Mysten Labs, Inc.
// Modifications Copyright (c) 2024 IOTA Stiftung
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;
use iota_types::base_types::EpochId;
use serde::Serialize;

use crate::{FileFormat, ParquetSchema};

pub mod csv_writer;
pub mod parquet_writer;

pub trait AnalyticsWriter<S: Serialize + ParquetSchema>: Send + Sync + 'static {
    /// File format i.e. csv, parquet, etc
    fn file_format(&self) -> Result<FileFormat>;
    /// Persist given rows into a file
    fn write(&mut self, rows: &[S]) -> Result<()>;
    /// Flush the current file
    fn flush(&mut self, end_checkpoint_seq_num: u64) -> Result<bool>;
    /// Reset internal state with given epoch and checkpoint sequence number
    fn reset(&mut self, epoch_num: EpochId, start_checkpoint_seq_num: u64) -> Result<()>;
    /// Approx size in bytes of the current staging file if available
    fn file_size(&self) -> Result<Option<u64>>;
}
