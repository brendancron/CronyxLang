use std::io::Write;

pub trait AsTree {
    fn as_tree(&self) -> Vec<TreeNode>;

    fn format_tree<W: Write>(&self, out: &mut W) {
        print_tree(&self.as_tree(), out);
    }
}

pub struct TreeNode {
    pub label: String,
    pub children: Vec<TreeNode>,
}

impl TreeNode {
    pub fn node(label: impl Into<String>, children: Vec<TreeNode>) -> Self {
        Self { label: label.into(), children }
    }

    pub fn leaf(label: impl Into<String>) -> Self {
        Self { label: label.into(), children: vec![] }
    }
}

pub fn print_tree<W: Write>(nodes: &[TreeNode], out: &mut W) {
    for (i, node) in nodes.iter().enumerate() {
        let last = i + 1 == nodes.len();
        print_node(node, "", last, out);
    }
}

fn print_node<W: Write>(node: &TreeNode, prefix: &str, last: bool, out: &mut W) {
    let branch = if last { "└─ " } else { "├─ " };
    writeln!(out, "{prefix}{branch}{}", node.label).unwrap();

    let new_prefix = format!(
        "{}{}",
        prefix,
        if last { "   " } else { "│  " }
    );

    for (i, child) in node.children.iter().enumerate() {
        let last_child = i + 1 == node.children.len();
        print_node(child, &new_prefix, last_child, out);
    }
}
