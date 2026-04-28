use std::collections::HashMap;
use std::path::Path;
use crate::config::SOURCE_FILE_EXT;

pub trait ExternalResolver {
    fn read_file(&self, curr_dir: &Path, relative_path: &str) -> Option<String>;
    fn read_mod(&self, curr_dir: &Path, name: &str) -> Option<String>;
}

pub struct DefaultResolver {}

impl ExternalResolver for DefaultResolver {
    fn read_file(&self, curr_dir: &Path, relative_path: &str) -> Option<String> {
        let path = curr_dir.join(relative_path);
        std::fs::read_to_string(&path).ok()
    }

    fn read_mod(&self, curr_dir: &Path, name: &str) -> Option<String> {
        let full = curr_dir.join(String::from(name) + SOURCE_FILE_EXT);
        std::fs::read_to_string(&full).ok()
    }

}

pub struct MapResolver {
    pub map: HashMap<String, String>,
}

impl ExternalResolver for MapResolver {
    fn read_file(&self, _curr_dir: &Path, relative_path: &str) -> Option<String> {
        self.map.get(relative_path).cloned()
    }

    fn read_mod(&self, _curr_dir: &Path, name: &str) -> Option<String> {
        self.map.get(name).cloned()
    }
}

pub struct DummyResolver {}


impl ExternalResolver for DummyResolver {
    fn read_file(&self, _curr_dir: &Path, relative_path: &str) -> Option<String> {
        Some(String::from("Dummy: ") + relative_path)
    }

    fn read_mod(&self, _curr_dir: &Path, name: &str) -> Option<String> {
        Some(String::from("Dummy: ") + name)
    }
}
