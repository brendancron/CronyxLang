pub struct IdProvider {
    current_id: usize,
}

impl IdProvider {
    pub fn new() -> Self {
        Self { current_id: 0 }
    }

    pub fn starting_from(n: usize) -> Self {
        Self { current_id: n }
    }

    pub fn next(&mut self) -> usize {
        let id = self.current_id;
        self.current_id += 1;
        id
    }
}
