import assert from 'node:assert/strict';

// Shared across injected service instances. Transactions commit atomically and
// serialize concurrent callbacks. Production never imports this fixture.
export class TransactionStore {
  data=new Map(); tail=Promise.resolve();
  collection(path){return {doc:id=>this.ref(`${path}/${id}`)};}
  ref(path){return {path,collection:name=>this.collection(`${path}/${name}`)};}
  snapshot(path){const data=this.data.get(path);return {exists:data!==undefined,data:()=>structuredClone(data)};}
  runTransaction(callback){
    const operation=this.tail.then(async()=>{
      const writes=[];let writing=false;
      const transaction={getAll:async(...refs)=>{assert.equal(writing,false);return refs.map(ref=>this.snapshot(ref.path));},set:(ref,data)=>{writing=true;writes.push(()=>this.data.set(ref.path,structuredClone(data)));}};
      const result=await callback(transaction);writes.forEach(write=>write());return result;
    });
    this.tail=operation.catch(()=>{});return operation;
  }
}
