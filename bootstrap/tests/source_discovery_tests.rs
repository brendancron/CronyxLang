use cronyx::frontend::source_discovery::*;

#[cfg(test)]
mod type_check_tests {

    use super::*;

    #[test]
    fn discovers_simple_import_chain() {
        let mut d = SourceDiscovery::new();
        d.discover("tests/fixtures/root.cx".into()).unwrap();

        let modules = d.modules();
        assert_eq!(modules.len(), 3);
    }

    #[test]
    fn missing_import_errors() {
        let mut d = SourceDiscovery::new();
        let err = d.discover("tests/fixtures/missing.cx".into()).unwrap_err();
        assert!(err.contains("import not found"));
    }

    #[test]
    fn handles_cycles_once() {
        let mut d = SourceDiscovery::new();
        d.discover("tests/fixtures/cycle_a.cx".into()).unwrap();

        let modules = d.modules();
        assert_eq!(modules.len(), 2);
    }

}
