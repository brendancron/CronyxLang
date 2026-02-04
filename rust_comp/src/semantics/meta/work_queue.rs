
#[derive(Debug)]
pub enum WorkItem {
    LowerExpr { meta_id: usize, runtime_id: usize },
    LowerStmt { meta_id: usize, runtime_id: usize },
}

pub struct WorkQueue {
    queue: VecDeque<WorkItem>,
}

impl WorkQueue {
    pub fn new() -> Self {
        Self {
            queue: VecDeque::new(),
        }
    }

    fn queue(&mut self, item: WorkItem) {
        self.queue.push_back(item);
    }

    pub fn queue_expr(&mut self, id_provider: &mut IdProvider, meta_id: usize) -> usize {
        let runtime_id = id_provider.next();
        let item = WorkItem::LowerExpr {
            meta_id,
            runtime_id,
        };
        self.queue(item);
        runtime_id
    }

    pub fn queue_stmt(&mut self, id_provider: &mut IdProvider, meta_id: usize) -> usize {
        let runtime_id = id_provider.next();
        let item = WorkItem::LowerStmt {
            meta_id,
            runtime_id,
        };
        self.queue(item);
        runtime_id
    }

    pub fn next(&mut self) -> Option<WorkItem> {
        self.queue.pop_front()
    }
}
