
#[test_only]
module surge_oracle::surge_oracle_tests;
// uncomment this line to import the module
use surge_oracle::vol_oracle;

const ENotImplemented: u64 = 0;

#[test]
fun test_surge_oracle() {
    // pass
}

#[test, expected_failure(abort_code = ::surge_oracle::surge_oracle_tests::ENotImplemented)]
fun test_surge_oracle_fail() {
    abort ENotImplemented
}

