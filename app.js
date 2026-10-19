(()=>{const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}}),{rootMargin:'0px 0px -8% 0px',threshold:.12});
document.querySelectorAll('.rv').forEach(el=>io.observe(el));
const nav=document.querySelector('.nav');addEventListener('scroll',()=>nav.classList.toggle('solid',scrollY>20),{passive:true});
})();
