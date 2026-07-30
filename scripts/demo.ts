const frames = [
` /\\_/\\\\
( o.o )
 > ^ <`,

` /\\_/\\\\
( -.- )
 > ^ <`,

` /\\_/\\\\
( o.o )
 > ^ <`,

` /\\_/\\\\
( ^.^ )
 > ^ <`
];

let i = 0;

setInterval(() => {
  console.clear();
  console.log(frames[i++ % frames.length]);
}, 300);