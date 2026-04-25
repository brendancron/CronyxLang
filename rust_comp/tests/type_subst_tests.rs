use cronyx::semantics::types::type_subst::{unify, ApplySubst, TypeSubst};
use cronyx::semantics::types::types::*;

#[cfg(test)]
mod type_subst_tests {
    use super::*;

    fn tv(n: usize) -> Type {
        Type::Var(TypeVar { id: n })
    }

    fn int() -> Type {
        int_type()
    }

    fn bool_() -> Type {
        bool_type()
    }

    #[test]
    fn apply_substitution_simple() {
        let mut subst = TypeSubst::new();
        subst.map.insert(TypeVar { id: 0 }, int());

        let t = tv(0);
        assert_eq!(t.apply(&subst), int());
    }

    #[test]
    fn apply_substitution_recursive_func() {
        let mut subst = TypeSubst::new();
        subst.map.insert(TypeVar { id: 0 }, int());

        let t = Type::Func { effects: EffectRow::empty(), params: vec![tv(0)],
            ret: Box::new(tv(0)),
        };

        let applied = t.apply(&subst);

        assert_eq!(
            applied,
            Type::Func { effects: EffectRow::empty(), params: vec![int()],
                ret: Box::new(int()),
            }
        );
    }

    #[test]
    fn unify_var_with_primitive() {
        let mut subst = TypeSubst::new();

        unify(&tv(0), &int(), &mut subst).unwrap();

        assert_eq!(subst.map.get(&TypeVar { id: 0 }), Some(&int()));
    }

    #[test]
    fn unify_same_primitive() {
        let mut subst = TypeSubst::new();

        unify(&int(), &int(), &mut subst).unwrap();
        assert!(subst.map.is_empty());
    }

    #[test]
    fn unify_function_types() {
        let mut subst = TypeSubst::new();

        let f1 = Type::Func { effects: EffectRow::empty(), params: vec![tv(0)],
            ret: Box::new(tv(0)),
        };

        let f2 = Type::Func { effects: EffectRow::empty(), params: vec![int()],
            ret: Box::new(int()),
        };

        unify(&f1, &f2, &mut subst).unwrap();

        assert_eq!(subst.map.get(&TypeVar { id: 0 }), Some(&int()));
    }

    #[test]
    fn unify_mismatch_errors() {
        let mut subst = TypeSubst::new();

        let err = unify(&int(), &bool_(), &mut subst);
        assert!(err.is_err());
    }

    #[test]
    fn occurs_check_rejects_infinite_type() {
        let mut subst = TypeSubst::new();

        let t = tv(0);
        let bad = Type::Func { effects: EffectRow::empty(), params: vec![tv(0)],
            ret: Box::new(int()),
        };

        let err = unify(&t, &bad, &mut subst);
        assert!(err.is_err());
    }
}
