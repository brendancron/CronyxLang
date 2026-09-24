import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  Svg: React.ComponentType<React.ComponentProps<'svg'>>;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Easy to start, no ceiling',
    Svg: require('@site/static/img/undraw_docusaurus_mountain.svg').default,
    description: (
      <>
        Fast to code in: inference keeps annotations few, and generics,
        effects and metaprogramming are there from the first line.
      </>
    ),
  },
  {
    title: 'Metaprogramming, first-class',
    Svg: require('@site/static/img/undraw_docusaurus_tree.svg').default,
    description: (
      <>
        Run code at compile time with <code>meta</code> blocks, generate runtime
        code with <code>gen</code>, and reflect on types with <code>typeof</code>.
        Generics are just compile-time parameters — the same machinery, with
        friendlier syntax.
      </>
    ),
  },
  {
    title: 'Static types, resolved early',
    Svg: require('@site/static/img/undraw_docusaurus_react.svg').default,
    description: (
      <>
        Hindley–Milner inference catches mistakes before your program runs.
        Generics monomorphize, meta computations bake into literal values, and
        traits dispatch statically. Code nothing reaches is never emitted.
      </>
    ),
  },
];

function Feature({title, Svg, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center">
        <Svg className={styles.featureSvg} role="img" />
      </div>
      <div className="text--center padding-horiz--md">
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
