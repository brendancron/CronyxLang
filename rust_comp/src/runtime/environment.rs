use super::value::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub struct EnvHandler {
    env: EnvRef,
}

pub type EnvRef = Rc<RefCell<Environment>>;

impl EnvHandler {
    pub fn new() -> Self {
        Self {
            env: Environment::new(),
        }
    }

    pub fn from(env: EnvRef) -> Self {
        Self { env }
    }

    pub fn push_scope(&mut self) {
        let new_env = Environment::new_child(self.env.clone());
        self.env = new_env;
    }

    pub fn pop_scope(&mut self) {
        let parent = {
            let env = self.env.borrow();
            env.parent.clone()
        };

        if let Some(parent) = parent {
            self.env = parent;
        }
    }

    pub fn env_ref(&self) -> EnvRef {
        self.env.clone()
    }

    pub fn define(&mut self, name: String, value: Value) {
        self.env.borrow_mut().define(name, value);
    }

    pub fn get(&self, name: &str) -> Result<Value, String> {
        self.env.borrow().get(name)
    }

    pub fn assign(&mut self, name: &str, value: Value) -> Result<(), String> {
        self.env.borrow_mut().assign(name, value)
    }
}

#[derive(Debug, Clone)]
pub struct Environment {
    values: HashMap<String, Value>,
    pub parent: Option<Rc<RefCell<Environment>>>,
}

impl Environment {
    pub fn new() -> Rc<RefCell<Environment>> {
        Rc::new(RefCell::new(Environment {
            values: HashMap::new(),
            parent: None,
        }))
    }

    pub fn new_child(parent: Rc<RefCell<Environment>>) -> Rc<RefCell<Environment>> {
        Rc::new(RefCell::new(Environment {
            values: HashMap::new(),
            parent: Some(parent),
        }))
    }

    pub fn define(&mut self, name: String, value: Value) {
        self.values.insert(name, value);
    }

    pub fn assign(&mut self, name: &str, value: Value) -> Result<(), String> {
        if self.values.contains_key(name) {
            self.values.insert(name.to_string(), value);
            return Ok(());
        }

        if let Some(parent) = &self.parent {
            return parent.borrow_mut().assign(name, value);
        }

        Err(format!("Undefined variable: '{}'", name))
    }

    pub fn exists(&self, name: &str) -> bool {
        if self.values.contains_key(name) {
            return true;
        }

        if let Some(parent) = &self.parent {
            return parent.borrow().exists(name);
        }

        false
    }

    pub fn get(&self, name: &str) -> Result<Value, String> {
        if let Some(value) = self.values.get(name) {
            return Ok(value.clone());
        }

        if let Some(parent) = &self.parent {
            return parent.borrow().get(name);
        }

        Err(format!("Undefined variable: '{}'", name))
    }
}
