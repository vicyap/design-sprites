// One emit interface. Closed vocabularies. Never log content or tokens.
export type Result='succeeded'|'failed'|'skipped'|'retried'|'degraded'|'unknown';
export type Reason='ok'|'db_error'|'auth_failed'|'validation'|'not_found'|'unknown';
export function emit(event:string,result:Result,reason:Reason,meta:Record<string,string|number>={}){
  const rec={ts:new Date().toISOString(),event,result,reason,...meta};
  console.log(JSON.stringify(rec));
}
