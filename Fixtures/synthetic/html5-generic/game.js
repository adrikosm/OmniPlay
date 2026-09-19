const c=document.getElementById('c');
const runs=Number(localStorage.getItem('runs')||0)+1;localStorage.setItem('runs',String(runs));document.title='Generic run '+runs;
