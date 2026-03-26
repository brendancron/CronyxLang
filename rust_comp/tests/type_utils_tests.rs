#![cfg(any())] // disabled: type modules temporarily removed
use cronyx::semantics::types::type_env::*;
use cronyx::semantics::types::type_utils::*;
use cronyx::semantics::types::types::*;

#[cfg(test)]
mod type_utils_tests {
    use super::*;

    #[cfg(test)]
    mod free_vars_tests {
        use super::*;

        #[test]
        fn free_vars_simple_var() {
            let t = type_var(0);
            let vars = t.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 0 }].into());
        }

        #[test]
        fn free_vars_primitive() {
            let t = int_type();
            assert!(t.free_type_vars().is_empty());
        }

        #[test]
        fn free_vars_function() {
            let t = Type::Func {
                params: vec![type_var(0), type_var(1)],
                ret: Box::new(type_var(0)),
            };

            let vars = t.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 0 }, TypeVar { id: 1 }].into());
        }

        #[test]
        fn free_vars_mono_scheme() {
            let scheme = TypeScheme::MonoType(Type::Func {
                params: vec![type_var(0)],
                ret: Box::new(type_var(1)),
            });

            let vars = scheme.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 0 }, TypeVar { id: 1 }].into());
        }

        #[test]
        fn free_vars_poly_scheme_removes_quantified() {
            let scheme = TypeScheme::PolyType {
                vars: vec![TypeVar { id: 0 }],
                ty: Type::Func {
                    params: vec![type_var(0)],
                    ret: Box::new(type_var(1)),
                },
            };

            let vars = scheme.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 1 }].into());
        }

        #[test]
        fn free_vars_empty_env() {
            let env = TypeEnv::new();
            let vars = env.free_type_vars();
            assert!(vars.is_empty());
        }

        #[test]
        fn free_vars_env_single_mono() {
            let mut env = TypeEnv::new();

            env.bind(
                "x",
                TypeScheme::MonoType(Type::Func {
                    params: vec![type_var(0)],
                    ret: Box::new(type_var(1)),
                }),
            );

            let vars = env.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 0 }, TypeVar { id: 1 }].into());
        }

        #[test]
        fn free_vars_env_poly_hides_quantified() {
            let mut env = TypeEnv::new();

            env.bind(
                "id",
                TypeScheme::PolyType {
                    vars: vec![TypeVar { id: 0 }],
                    ty: Type::Func {
                        params: vec![type_var(0)],
                        ret: Box::new(type_var(0)),
                    },
                },
            );

            let vars = env.free_type_vars();
            assert!(vars.is_empty());
        }

        #[test]
        fn free_vars_env_mixed_bindings() {
            let mut env = TypeEnv::new();

            env.bind(
                "id",
                TypeScheme::PolyType {
                    vars: vec![TypeVar { id: 0 }],
                    ty: Type::Func {
                        params: vec![type_var(0)],
                        ret: Box::new(type_var(0)),
                    },
                },
            );

            env.bind(
                "f",
                TypeScheme::MonoType(Type::Func {
                    params: vec![type_var(1)],
                    ret: Box::new(int_type()),
                }),
            );

            let vars = env.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 1 }].into());
        }

        #[test]
        fn free_vars_env_nested_scopes() {
            let mut env = TypeEnv::new();

            env.bind("x", TypeScheme::MonoType(type_var(0)));

            env.push_scope();
            env.bind("y", TypeScheme::MonoType(type_var(1)));

            let vars = env.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 0 }, TypeVar { id: 1 }].into());

            env.pop_scope();

            let vars = env.free_type_vars();
            assert_eq!(vars, [TypeVar { id: 0 }].into());
        }
    }

    #[cfg(test)]
    mod generalization_tests {
        use super::*;

        #[test]
        fn generalize_concrete_type_is_mono() {
            let env = TypeEnv::new();
            let scheme = generalize(&env, int_type());

            match scheme {
                TypeScheme::MonoType(t) => assert_eq!(t, int_type()),
                _ => panic!("expected Mono"),
            }
        }

        #[test]
        fn generalize_simple_identity() {
            let env = TypeEnv::new();

            let ty = Type::Func {
                params: vec![type_var(0)],
                ret: Box::new(type_var(0)),
            };

            let scheme = generalize(&env, ty.clone());

            match scheme {
                TypeScheme::PolyType { vars, ty: body } => {
                    assert_eq!(vars, vec![TypeVar { id: 0 }]);
                    assert_eq!(body, ty);
                }
                _ => panic!("expected Poly"),
            }
        }

        #[test]
        fn generalize_excludes_env_vars() {
            let mut env = TypeEnv::new();

            env.bind("x", TypeScheme::MonoType(type_var(0)));

            let ty = Type::Func {
                params: vec![type_var(0)],
                ret: Box::new(type_var(1)),
            };

            let scheme = generalize(&env, ty);

            match scheme {
                TypeScheme::PolyType { vars, .. } => {
                    assert_eq!(vars, vec![TypeVar { id: 1 }]);
                }
                _ => panic!("expected Poly"),
            }
        }
    }

    #[cfg(test)]
    mod instantiation_tests {
        use super::*;

        #[test]
        fn instantiate_mono_returns_same_type() {
            let mut env = TypeEnv::new();

            let scheme = TypeScheme::MonoType(int_type());
            let t1 = instantiate(&scheme, &mut env);
            let t2 = instantiate(&scheme, &mut env);

            assert_eq!(t1, int_type());
            assert_eq!(t2, int_type());
        }

        #[test]
        fn instantiate_poly_freshens_vars() {
            let mut env = TypeEnv::new();

            let scheme = TypeScheme::PolyType {
                vars: vec![TypeVar { id: 0 }],
                ty: Type::Func {
                    params: vec![type_var(0)],
                    ret: Box::new(type_var(0)),
                },
            };

            let t1 = instantiate(&scheme, &mut env);
            let t2 = instantiate(&scheme, &mut env);

            assert_ne!(t1, t2);

            match (t1, t2) {
                (
                    Type::Func {
                        params: p1,
                        ret: r1,
                    },
                    Type::Func {
                        params: p2,
                        ret: r2,
                    },
                ) => {
                    assert_eq!(p1.len(), 1);
                    assert_eq!(p2.len(), 1);
                    assert_eq!(p1[0], *r1);
                    assert_eq!(p2[0], *r2);
                    assert_ne!(p1[0], p2[0]);
                }
                _ => panic!("expected functions"),
            }
        }

        #[test]
        fn generalize_then_instantiate_identity_twice() {
            let mut env = TypeEnv::new();

            let id_ty = Type::Func {
                params: vec![type_var(0)],
                ret: Box::new(type_var(0)),
            };

            let scheme = generalize(&env, id_ty);
            let t1 = instantiate(&scheme, &mut env);
            let t2 = instantiate(&scheme, &mut env);

            assert_ne!(t1, t2);
        }
    }
}
